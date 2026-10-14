"Message class: ZLOAD_REJ_MSG. Maintain the accompanying SE91 texts first.
TYPES:
  BEGIN OF ty_load_message,
    number TYPE symsgno,
    v1     TYPE symsgv,
    v2     TYPE symsgv,
    v3     TYPE symsgv,
    v4     TYPE symsgv,
  END OF ty_load_message.

CLASS lhc_header DEFINITION
  INHERITING FROM cl_abap_behavior_handler.


  PUBLIC SECTION.
    CLASS-METHODS GetSerialLock
      IMPORTING
        is_header TYPE ZI_LOAD_REJ_HDR
        is_item   TYPE ZI_LOAD_REJ_ITM
      RETURNING VALUE(rv_error) TYPE ty_load_message.

  PRIVATE SECTION.

    METHODS get_instance_authorizations
      FOR INSTANCE AUTHORIZATION
      keys REQUEST requested_authorizations
      FOR Header RESULT result.

    METHODS get_global_authorizations
      FOR GLOBAL AUTHORIZATION
      REQUEST requested_authorizations
      FOR Header RESULT result.

    METHODS Fetch FOR MODIFY
      IMPORTING keys FOR ACTION Header~Fetch
      RESULT result.

      METHODS FetchSerials FOR MODIFY
  IMPORTING keys FOR ACTION Header~FetchSerials
  RESULT result.

    METHODS ValidateSerials FOR VALIDATE ON SAVE
      IMPORTING keys FOR Header~ValidateSerials.

    METHODS ValidateOrderAndPosting FOR VALIDATE ON SAVE
      IMPORTING keys FOR Header~ValidateOrderAndPosting.
    METHODS get_instance_features FOR INSTANCE FEATURES
      keys REQUEST requested_features FOR Header RESULT result.
    METHODS precheck_delete FOR PRECHECK
      IMPORTING keys FOR DELETE Header.

ENDCLASS.


CLASS lhc_header IMPLEMENTATION.

  METHOD get_instance_authorizations.

    "Development permissions: replace with actual checks.
    result = VALUE #(
      FOR key IN keys
      (
        %tky    = key-%tky
        %update = if_abap_behv=>auth-allowed
        %delete = if_abap_behv=>auth-allowed
      )
    ).

  ENDMETHOD.


  METHOD get_global_authorizations.

    result-%create = if_abap_behv=>auth-allowed.

  ENDMETHOD.


 METHOD Fetch.

  DATA:
    lv_order         TYPE c LENGTH 12,
    lv_item_order    TYPE c LENGTH 12,
    lv_work_center   TYPE c LENGTH 8,
    lv_error TYPE ty_load_message,
    lv_loaded_qty    TYPE p LENGTH 16 DECIMALS 3,
    lv_rejection_qty TYPE p LENGTH 16 DECIMALS 3,
    lv_quantity_unit TYPE c LENGTH 3,
    lv_confirmed     TYPE abap_bool,
    lv_has_quantity  TYPE abap_bool.

  READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
    ENTITY Header
    ALL FIELDS
    WITH CORRESPONDING #( keys )
    RESULT DATA(lt_headers)
    FAILED DATA(ls_read_failed)
    REPORTED DATA(ls_read_reported).

  failed   = CORRESPONDING #( ls_read_failed ).
  reported = CORRESPONDING #( ls_read_reported ).

  LOOP AT lt_headers INTO DATA(ls_header).

    CLEAR:
      lv_order,
      lv_item_order,
      lv_work_center,
      lv_error,
      lv_loaded_qty,
      lv_rejection_qty,
      lv_quantity_unit,
      lv_confirmed,
      lv_has_quantity.

    "1. Check draft and entered order number
    IF ls_header-%is_draft <> if_abap_behv=>mk-on.

      lv_error = VALUE ty_load_message( number = '001' ).

    ELSEIF ls_header-ProdOrder IS INITIAL.

      lv_error = VALUE ty_load_message( number = '002' ).

    ENDIF.

    "2. Convert the order number and read order details
    IF lv_error IS INITIAL.

      lv_order = ls_header-ProdOrder.
      lv_order = |{ lv_order ALPHA = IN WIDTH = 12 }|.

      SELECT SINGLE
        ManufacturingOrder,
        ManufacturingOrderType,
        ProductionPlant,
        Material,
        Batch,
        ProductionUnit,
        OrderIsReleased,
        IsMarkedForDeletion
        FROM I_ManufacturingOrderItem
        WHERE ManufacturingOrder = @lv_order
          AND ManufacturingOrderItem = '0001'
        INTO @DATA(ls_order).

      IF sy-subrc <> 0.

        lv_error = VALUE ty_load_message( number = '003' ).

      ELSEIF ls_order-IsMarkedForDeletion IS NOT INITIAL.

        lv_error = VALUE ty_load_message( number = '004' ).

      ELSEIF ls_order-OrderIsReleased IS INITIAL.

        lv_error = VALUE ty_load_message( number = '005' ).

      ENDIF.

    ENDIF.

    "3. Check active system statuses
    IF lv_error IS INITIAL.

      SELECT StatusCode
        FROM I_ManufacturingOrderStatus
        WHERE ManufacturingOrder = @lv_order
          AND StatusIsActive = @abap_true
          AND IsUserStatus = @abap_false
        INTO TABLE @DATA(lt_status).

      IF lt_status IS INITIAL.

        lv_error = VALUE ty_load_message( number = '006' ).

      ELSEIF line_exists(
        lt_status[ StatusCode = 'I0045' ] )
        OR line_exists(
        lt_status[ StatusCode = 'I0046' ] ).

        lv_error = VALUE ty_load_message( number = '007' ).

      ELSEIF NOT line_exists(
        lt_status[ StatusCode = 'I0002' ] ).

        lv_error = VALUE ty_load_message( number = '005' ).

      ELSE.

        lv_confirmed = xsdbool(
          line_exists( lt_status[ StatusCode = 'I0009' ] )
          OR
          line_exists( lt_status[ StatusCode = 'I0010' ] )
        ).

      ENDIF.

    ENDIF.

    "4. Check that existing serials belong to this order
    IF lv_error IS INITIAL.

      READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
        ENTITY Header BY \_Items
        FIELDS ( ProdOrder )
        WITH VALUE #( ( %tky = ls_header-%tky ) )
        RESULT DATA(lt_items)
        FAILED DATA(ls_items_failed)
        REPORTED DATA(ls_items_reported).

      APPEND LINES OF ls_items_reported-header
        TO reported-header.

      APPEND LINES OF ls_items_reported-item
        TO reported-item.

      IF ls_items_failed IS NOT INITIAL.

        lv_error = VALUE ty_load_message( number = '008' ).

      ELSE.

        LOOP AT lt_items INTO DATA(ls_item).

          lv_item_order = ls_item-ProdOrder.
          lv_item_order =
            |{ lv_item_order ALPHA = IN WIDTH = 12 }|.

          IF lv_item_order <> lv_order.

            lv_error =
              VALUE ty_load_message( number = '009' ).

            EXIT.

          ENDIF.

        ENDLOOP.

      ENDIF.

    ENDIF.

    "5. Fetch movement quantities using OrderID
    IF lv_error IS INITIAL.

      SELECT
        MaterialDocumentYear,
        MaterialDocument,
        MaterialDocumentItem,
        Material,
        Batch,
        GoodsMovementType,
        QuantityInBaseUnit,
        MaterialBaseUnit,
        ReversedMaterialDocumentYear,
        ReversedMaterialDocument,
        ReversedMaterialDocumentItem
        FROM I_MaterialDocumentItem_2
        WHERE OrderID = @lv_order
          AND ( GoodsMovementType = '261'
             OR GoodsMovementType = '262'
             OR GoodsMovementType = '531'
              OR GoodsMovementType = '532' )
        INTO TABLE @DATA(lt_quantity_movements).

      LOOP AT lt_quantity_movements
        INTO DATA(ls_quantity_movement).

        "262 is used to identify reversed 261 documents
        IF ls_quantity_movement-GoodsMovementType = '262'.
          CONTINUE.
        ENDIF.

        IF ls_quantity_movement-GoodsMovementType = '261'.

          IF ls_quantity_movement-ReversedMaterialDocument
             IS NOT INITIAL.
            CONTINUE.
          ENDIF.

          "Exclude the original 261 item referenced by a 262
          IF line_exists(
            lt_quantity_movements[
              GoodsMovementType = '262'
              ReversedMaterialDocumentYear =
                ls_quantity_movement-MaterialDocumentYear
              ReversedMaterialDocument =
                ls_quantity_movement-MaterialDocument
              ReversedMaterialDocumentItem =
                ls_quantity_movement-MaterialDocumentItem
            ]
          ).
            CONTINUE.
          ENDIF.

        ENDIF.

        IF ls_quantity_movement-MaterialBaseUnit IS INITIAL.

          lv_error = VALUE ty_load_message( number = '010' ).
          EXIT.

        ENDIF.

        IF lv_quantity_unit IS INITIAL.

          lv_quantity_unit =
            ls_quantity_movement-MaterialBaseUnit.

        ELSEIF lv_quantity_unit
               <> ls_quantity_movement-MaterialBaseUnit.

          lv_error =
            VALUE ty_load_message( number = '011' ).

          EXIT.

        ENDIF.

        lv_has_quantity = abap_true.

        CASE ls_quantity_movement-GoodsMovementType.

  WHEN '261'.
    lv_loaded_qty =
      lv_loaded_qty
      + abs( ls_quantity_movement-QuantityInBaseUnit ).

  WHEN '531'.
    lv_rejection_qty =
      lv_rejection_qty
      + abs( ls_quantity_movement-QuantityInBaseUnit ).

  WHEN '532'.
    lv_rejection_qty =
      lv_rejection_qty
      - abs( ls_quantity_movement-QuantityInBaseUnit ).

ENDCASE.

      ENDLOOP.

      IF lv_quantity_unit IS INITIAL.
        lv_quantity_unit = ls_order-ProductionUnit.
      ENDIF.

    ENDIF.

    "6. Fetch Work Center from manufacturing order operations
    IF lv_error IS INITIAL.

      SELECT DISTINCT
        wc~WorkCenter
        FROM I_ManufacturingOrderOperation AS op
        INNER JOIN I_WorkCenter AS wc
          ON wc~WorkCenterInternalID = op~WorkCenterInternalID
        WHERE op~ManufacturingOrder = @lv_order
        INTO TABLE @DATA(lt_work_centers).

      DELETE lt_work_centers WHERE WorkCenter IS INITIAL.

      IF lt_work_centers IS INITIAL.

        lv_error = VALUE ty_load_message( number = '012' ).

      ELSEIF lines( lt_work_centers ) > 1.

        lv_error =
          VALUE ty_load_message( number = '013' ).

      ELSE.

        lv_work_center = lt_work_centers[ 1 ]-WorkCenter.

      ENDIF.

    ENDIF.


    IF lv_error IS INITIAL.
      READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
        ENTITY Header BY \_Items ALL FIELDS
        WITH VALUE #( ( %tky = ls_header-%tky ) )
        RESULT DATA(lt_posting_check_items)
        FAILED DATA(ls_posting_check_failed).
      IF ls_posting_check_failed IS NOT INITIAL.
        lv_error = VALUE ty_load_message( number = '014' ).
      ELSE.
        LOOP AT lt_posting_check_items INTO DATA(ls_posting_check_item).
          lv_error = GetSerialLock(
            is_header = CORRESPONDING #( ls_header )
            is_item = CORRESPONDING #( ls_posting_check_item ) ).
          IF lv_error IS NOT INITIAL.
            EXIT.
          ENDIF.
        ENDLOOP.
      ENDIF.
    ENDIF.

    "7. Report errors before updating the draft
    IF lv_error IS NOT INITIAL.

      APPEND VALUE #(
        %tky = ls_header-%tky
      ) TO failed-header.

      APPEND VALUE #(
        %tky = ls_header-%tky
        %msg = new_message(
            id       = 'ZLOAD_REJ_MSG'
            number   = lv_error-number
            severity = if_abap_behv_message=>severity-error
            v1       = lv_error-v1
            v2       = lv_error-v2
            v3       = lv_error-v3
            v4       = lv_error-v4
          )
      ) TO reported-header.

      CONTINUE.

    ENDIF.

    "8. Update the draft with fetched values
    MODIFY ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Header
      UPDATE FIELDS (
        ProdOrder
        Plant
        OrderType
        WorkCenter
        Material
        BatchNumber
        QuantityUnit
        displayunit
        LoadedQty
        LoadingRejQty
      )
      WITH VALUE #(
        (
          %tky          = ls_header-%tky
          ProdOrder     = ls_header-ProdOrder
          Plant         = ls_order-ProductionPlant
          OrderType     = ls_order-ManufacturingOrderType
          WorkCenter    = lv_work_center
          Material      = ls_order-Material
          BatchNumber   = ls_order-Batch
          QuantityUnit  = lv_quantity_unit
          displayunit   = COND #(
            WHEN lv_quantity_unit = 'ST'
            THEN 'PC'
            ELSE lv_quantity_unit
          )
          LoadedQty     = lv_loaded_qty
          LoadingRejQty = lv_rejection_qty
        )
      )
      FAILED DATA(ls_update_failed)
      REPORTED DATA(ls_update_reported).

    APPEND LINES OF ls_update_failed-header
      TO failed-header.

    APPEND LINES OF ls_update_reported-header
      TO reported-header.

    IF ls_update_failed IS NOT INITIAL.
      CONTINUE.
    ENDIF.

    IF lv_confirmed = abap_true.

      APPEND VALUE #(
        %tky = ls_header-%tky
        %msg = new_message(
            id       = 'ZLOAD_REJ_MSG'
            number   = '038'
            severity = if_abap_behv_message=>severity-warning
          )
      ) TO reported-header.

    ENDIF.

    IF lv_has_quantity = abap_false.

      APPEND VALUE #(
        %tky = ls_header-%tky
        %msg = new_message(
            id       = 'ZLOAD_REJ_MSG'
            number   = '039'
            severity = if_abap_behv_message=>severity-information
          )
      ) TO reported-header.

    ENDIF.

    "9. Return the refreshed header
    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Header
      ALL FIELDS
      WITH VALUE #( ( %tky = ls_header-%tky ) )
      RESULT DATA(lt_updated)
      FAILED DATA(ls_return_failed)
      REPORTED DATA(ls_return_reported).

    APPEND LINES OF ls_return_failed-header
      TO failed-header.

    APPEND LINES OF ls_return_reported-header
      TO reported-header.

    LOOP AT lt_updated INTO DATA(ls_updated).

      APPEND VALUE #(
        %tky   = ls_updated-%tky
        %param = ls_updated
      ) TO result.

    ENDLOOP.

  ENDLOOP.

ENDMETHOD.

 METHOD FetchSerials.

  TYPES:
    BEGIN OF ty_balance,
      material  TYPE c LENGTH 40,
      serial_no TYPE c LENGTH 30,
      balance   TYPE i,
    END OF ty_balance,

    tt_balances TYPE SORTED TABLE OF ty_balance
      WITH UNIQUE KEY material serial_no,

    ty_serial_key TYPE c LENGTH 30,

    tt_serial_keys TYPE SORTED TABLE OF ty_serial_key
      WITH UNIQUE KEY table_line.

  DATA:
    lv_order          TYPE c LENGTH 12,
    lv_existing_order TYPE c LENGTH 12,
    lv_error TYPE ty_load_message,
    lv_index          TYPE i,
    lv_rejected_count TYPE i,
    lt_balances       TYPE tt_balances,
    lt_serial_keys    TYPE tt_serial_keys.

  DATA lt_create TYPE TABLE FOR CREATE
    ZI_LOAD_REJ_HDR\_Items.

  READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
    ENTITY Header
    ALL FIELDS
    WITH CORRESPONDING #( keys )
    RESULT DATA(lt_headers)
    FAILED DATA(ls_read_failed)
    REPORTED DATA(ls_read_reported).

  failed   = CORRESPONDING #( ls_read_failed ).
  reported = CORRESPONDING #( ls_read_reported ).

  LOOP AT lt_headers INTO DATA(ls_header).

    CLEAR:
      lv_order,
      lv_existing_order,
      lv_error,
      lv_index,
      lv_rejected_count,
      lt_balances,
      lt_serial_keys,
      lt_create.

    "1. Check current draft and order details
    IF ls_header-%is_draft <> if_abap_behv=>mk-on.

      lv_error = VALUE ty_load_message( number = '015' ).

    ELSEIF ls_header-ProdOrder IS INITIAL.

      lv_error = VALUE ty_load_message( number = '002' ).

    ELSEIF ls_header-Plant IS INITIAL.

      lv_error = VALUE ty_load_message( number = '016' ).

    ENDIF.

    IF lv_error IS INITIAL.

      lv_order = ls_header-ProdOrder.
      lv_order = |{ lv_order ALPHA = IN WIDTH = 12 }|.

      SELECT SINGLE
        ProductionPlant,
        ManufacturingOrderType,
        Material,
        OrderIsReleased,
        IsMarkedForDeletion
        FROM I_ManufacturingOrderItem
        WHERE ManufacturingOrder = @lv_order
          AND ManufacturingOrderItem = '0001'
        INTO @DATA(ls_order).

      IF sy-subrc <> 0.

        lv_error = VALUE ty_load_message( number = '003' ).

      ELSEIF ls_order-IsMarkedForDeletion IS NOT INITIAL.

        lv_error = VALUE ty_load_message( number = '004' ).

      ELSEIF ls_order-OrderIsReleased IS INITIAL.

        lv_error = VALUE ty_load_message( number = '005' ).

      ELSEIF ls_header-Plant <> ls_order-ProductionPlant
        OR ls_header-OrderType <> ls_order-ManufacturingOrderType
        OR ls_header-Material <> ls_order-Material.

        lv_error = VALUE ty_load_message( number = '017' ).

      ENDIF.

    ENDIF.

    "2. Recheck current order status
    IF lv_error IS INITIAL.

      SELECT StatusCode
        FROM I_ManufacturingOrderStatus
        WHERE ManufacturingOrder = @lv_order
          AND StatusIsActive = @abap_true
          AND IsUserStatus = @abap_false
        INTO TABLE @DATA(lt_status).

      IF lt_status IS INITIAL.

        lv_error = VALUE ty_load_message( number = '006' ).

      ELSEIF line_exists(
        lt_status[ StatusCode = 'I0045' ] )
        OR line_exists(
        lt_status[ StatusCode = 'I0046' ] ).

        lv_error = VALUE ty_load_message( number = '007' ).

      ELSEIF NOT line_exists(
        lt_status[ StatusCode = 'I0002' ] ).

        lv_error = VALUE ty_load_message( number = '005' ).

      ELSEIF line_exists(
        lt_status[ StatusCode = 'I0009' ] )
        OR line_exists(
        lt_status[ StatusCode = 'I0010' ] ).

        APPEND VALUE #(
          %tky = ls_header-%tky
          %msg = new_message(
            id       = 'ZLOAD_REJ_MSG'
            number   = '040'
            severity = if_abap_behv_message=>severity-warning
          )
        ) TO reported-header.

      ENDIF.

    ENDIF.

    "3. NEW CHECK: consumption material document must exist
    IF lv_error IS INITIAL.

      SELECT SINGLE MaterialDocument
        FROM I_MaterialDocumentItem_2
        WHERE OrderID = @lv_order
          AND GoodsMovementType = '261'
        INTO @DATA(lv_consumption_document).

      IF sy-subrc <> 0.
        lv_error = VALUE ty_load_message( number = '018' ).
      ENDIF.

    ENDIF.

    "4. Read serial movement history
    IF lv_error IS INITIAL.

      SELECT DISTINCT
        doc~MaterialDocumentYear,
        doc~MaterialDocument,
        doc~MaterialDocumentItem,
        doc~GoodsMovementType,
        serial~Material,
        serial~SerialNumber
        FROM I_MaterialDocumentItem_2 AS doc
        INNER JOIN I_SerialNumberMaterialDoc_2 AS serial
          ON serial~MaterialDocumentYear =
               doc~MaterialDocumentYear
         AND serial~MaterialDocument =
               doc~MaterialDocument
         AND serial~MaterialDocumentItem =
               doc~MaterialDocumentItem
        WHERE doc~OrderID = @lv_order
          AND ( doc~GoodsMovementType = '261'
             OR doc~GoodsMovementType = '262' )
        INTO TABLE @DATA(lt_movements).

      "One serial assignment represents one piece
      LOOP AT lt_movements INTO DATA(ls_movement).

        IF ls_movement-SerialNumber IS INITIAL.
          lv_error = VALUE ty_load_message( number = '019' ).
          EXIT.
        ENDIF.

        READ TABLE lt_balances
          ASSIGNING FIELD-SYMBOL(<balance>)
          WITH TABLE KEY
            material  = ls_movement-Material
            serial_no = ls_movement-SerialNumber.

        IF sy-subrc <> 0.

          INSERT VALUE #(
            material  = ls_movement-Material
            serial_no = ls_movement-SerialNumber
            balance   = 0
          ) INTO TABLE lt_balances.

          READ TABLE lt_balances
            ASSIGNING <balance>
            WITH TABLE KEY
              material  = ls_movement-Material
              serial_no = ls_movement-SerialNumber.

        ENDIF.

        CASE ls_movement-GoodsMovementType.
          WHEN '261'.
            <balance>-balance = <balance>-balance + 1.
          WHEN '262'.
            <balance>-balance = <balance>-balance - 1.
        ENDCASE.

      ENDLOOP.

      IF lv_error IS INITIAL.

        LOOP AT lt_balances INTO DATA(ls_balance).

          IF ls_balance-balance < 0
             OR ls_balance-balance > 1.

            lv_error =
              VALUE ty_load_message( number = '020'
          v1 = |{ ls_balance-serial_no }| ).

            EXIT.

          ENDIF.

        ENDLOOP.

        DELETE lt_balances WHERE balance = 0.

        IF lv_error IS INITIAL AND lt_balances IS INITIAL.
          lv_error = VALUE ty_load_message( number = '021' ).
        ENDIF.

      ENDIF.

    ENDIF.

    "5. Check serial uniqueness against the item key
    IF lv_error IS INITIAL.

      LOOP AT lt_balances INTO ls_balance.

        INSERT ls_balance-serial_no INTO TABLE lt_serial_keys.

        IF sy-subrc <> 0.

          lv_error =
            VALUE ty_load_message( number = '022'
          v1 = |{ ls_balance-serial_no }| ).

          EXIT.

        ENDIF.

      ENDLOOP.

    ENDIF.

    "6. Read and check existing draft items
    IF lv_error IS INITIAL.

      READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
        ENTITY Header BY \_Items
        ALL FIELDS
        WITH VALUE #( ( %tky = ls_header-%tky ) )
        RESULT DATA(lt_existing)
        FAILED DATA(ls_existing_failed)
        REPORTED DATA(ls_existing_reported).

      APPEND LINES OF ls_existing_reported-header
        TO reported-header.

      APPEND LINES OF ls_existing_reported-item
        TO reported-item.

      IF ls_existing_failed IS NOT INITIAL.

        lv_error = VALUE ty_load_message( number = '023' ).

      ELSE.

        LOOP AT lt_existing INTO DATA(ls_existing).

          lv_existing_order = ls_existing-ProdOrder.
          lv_existing_order =
            |{ lv_existing_order ALPHA = IN WIDTH = 12 }|.

          IF lv_existing_order <> lv_order.

            lv_error =
              VALUE ty_load_message( number = '009' ).

            EXIT.

          ENDIF.

          IF NOT line_exists(
            lt_balances[
              material  = ls_existing-Material
              serial_no = ls_existing-SerialNo
            ]
          ).

            lv_error =
              VALUE ty_load_message( number = '024' ).

            EXIT.

          ENDIF.

          IF ls_existing-Reject = abap_true.
            lv_rejected_count = lv_rejected_count + 1.
          ENDIF.

        ENDLOOP.

      ENDIF.

    ENDIF.


    IF lv_error IS INITIAL.
      READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
        ENTITY Header BY \_Items ALL FIELDS
        WITH VALUE #( ( %tky = ls_header-%tky ) )
        RESULT DATA(lt_posting_check_items)
        FAILED DATA(ls_posting_check_failed).
      IF ls_posting_check_failed IS NOT INITIAL.
        lv_error = VALUE ty_load_message( number = '014' ).
      ELSE.
        LOOP AT lt_posting_check_items INTO DATA(ls_posting_check_item).
          lv_error = GetSerialLock(
            is_header = CORRESPONDING #( ls_header )
            is_item = CORRESPONDING #( ls_posting_check_item ) ).
          IF lv_error IS NOT INITIAL.
            EXIT.
          ENDIF.
        ENDLOOP.
      ENDIF.
    ENDIF.

    "7. Report errors before changing any draft rows
    IF lv_error IS NOT INITIAL.

      APPEND VALUE #(
        %tky = ls_header-%tky
      ) TO failed-header.

      APPEND VALUE #(
        %tky = ls_header-%tky
        %msg = new_message(
            id       = 'ZLOAD_REJ_MSG'
            number   = lv_error-number
            severity = if_abap_behv_message=>severity-error
            v1       = lv_error-v1
            v2       = lv_error-v2
            v3       = lv_error-v3
            v4       = lv_error-v4
          )
      ) TO reported-header.

      CONTINUE.

    ENDIF.

    "8. Populate OrderType on existing draft serial rows
    IF lt_existing IS NOT INITIAL.

      MODIFY ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
        ENTITY Item
        UPDATE FIELDS ( OrderType DisplaySerialNo )
       WITH VALUE #(
  FOR ls_existing_item IN lt_existing
  (
    %tky           = ls_existing_item-%tky
    OrderType      = ls_header-OrderType
    DisplaySerialNo =
      |{ ls_existing_item-SerialNo ALPHA = OUT }|
  )
)
        FAILED DATA(ls_type_failed)
        REPORTED DATA(ls_type_reported).

      APPEND LINES OF ls_type_failed-header
        TO failed-header.

      APPEND LINES OF ls_type_failed-item
        TO failed-item.

      APPEND LINES OF ls_type_reported-header
        TO reported-header.

      APPEND LINES OF ls_type_reported-item
        TO reported-item.

      IF ls_type_failed IS NOT INITIAL.

        IF ls_type_failed-header IS INITIAL.
          APPEND VALUE #(
            %tky = ls_header-%tky
          ) TO failed-header.
        ENDIF.

        CONTINUE.

      ENDIF.

    ENDIF.

    "9. Build missing serial rows only
    APPEND INITIAL LINE TO lt_create
      ASSIGNING FIELD-SYMBOL(<create>).

    <create>-%tky = ls_header-%tky.

    LOOP AT lt_balances INTO ls_balance.

      "Preserve existing rejection values and remarks
      IF line_exists(
        lt_existing[ SerialNo = ls_balance-serial_no ]
      ).
        CONTINUE.
      ENDIF.

      lv_index = lv_index + 1.

      APPEND VALUE #(
        %cid      = |SERIAL_{ lv_index }|
        %is_draft = ls_header-%is_draft
        SerialNo  = ls_balance-serial_no
         DisplaySerialNo =
    |{ ls_balance-serial_no ALPHA = OUT }|
        ProdOrder = lv_order
        OrderType = ls_header-OrderType
        Stage     = ls_header-Stage
        Material  = ls_balance-material
        Reject    = abap_false
      ) TO <create>-%target.

    ENDLOOP.

    "No new serial rows: leave the create request empty
    IF <create>-%target IS INITIAL.
      CLEAR lt_create.
    ENDIF.

    "10. Update count and create draft serial rows
    MODIFY ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE

      ENTITY Header
      UPDATE FIELDS ( RejectedCount )
      WITH VALUE #(
        (
          %tky          = ls_header-%tky
          RejectedCount = lv_rejected_count
        )
      )

      ENTITY Header
      CREATE BY \_Items
      FIELDS (
        SerialNo
        DisplaySerialNo
        ProdOrder
        OrderType
        Stage
        Material
        Reject
      )
      WITH lt_create

      MAPPED DATA(ls_mapped)
      FAILED DATA(ls_modify_failed)
      REPORTED DATA(ls_modify_reported).

    APPEND LINES OF ls_modify_failed-header
      TO failed-header.

    APPEND LINES OF ls_modify_failed-item
      TO failed-item.

    APPEND LINES OF ls_modify_reported-header
      TO reported-header.

    APPEND LINES OF ls_modify_reported-item
      TO reported-item.

    IF ls_modify_failed IS NOT INITIAL.

      IF ls_modify_failed-header IS INITIAL.
        APPEND VALUE #(
          %tky = ls_header-%tky
        ) TO failed-header.
      ENDIF.

      APPEND VALUE #(
        %tky = ls_header-%tky
        %msg = new_message(
            id       = 'ZLOAD_REJ_MSG'
            number   = '041'
            severity = if_abap_behv_message=>severity-error
          )
      ) TO reported-header.

      CONTINUE.

    ENDIF.

    "11. Return the refreshed header
    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Header
      ALL FIELDS
      WITH VALUE #( ( %tky = ls_header-%tky ) )
      RESULT DATA(lt_updated)
      FAILED DATA(ls_return_failed)
      REPORTED DATA(ls_return_reported).

    APPEND LINES OF ls_return_failed-header
      TO failed-header.

    APPEND LINES OF ls_return_reported-header
      TO reported-header.

    LOOP AT lt_updated INTO DATA(ls_updated).

      APPEND VALUE #(
        %tky   = ls_updated-%tky
        %param = ls_updated
      ) TO result.

    ENDLOOP.

  ENDLOOP.

ENDMETHOD.

METHOD ValidateSerials.

  READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
    ENTITY Header
    FIELDS ( LoadingRejQty )
    WITH CORRESPONDING #( keys )
    RESULT DATA(lt_headers)
    FAILED DATA(ls_read_failed)
    REPORTED DATA(ls_read_reported).

  LOOP AT ls_read_failed-header INTO DATA(ls_failed_header).
    APPEND VALUE #(
      %tky = ls_failed_header-%tky
    ) TO failed-header.
  ENDLOOP.

  LOOP AT ls_read_reported-header INTO DATA(ls_read_header_msg).
    APPEND VALUE #(
      %tky = ls_read_header_msg-%tky
      %msg = ls_read_header_msg-%msg
    ) TO reported-header.
  ENDLOOP.

  LOOP AT ls_read_reported-item INTO DATA(ls_read_item_msg).
    APPEND VALUE #(
      %tky = ls_read_item_msg-%tky
      %msg = ls_read_item_msg-%msg
    ) TO reported-item.
  ENDLOOP.

  LOOP AT lt_headers INTO DATA(ls_header).

    "Clear previous header validation messages
    APPEND VALUE #(
      %tky        = ls_header-%tky
      %state_area = 'VALIDATE_SERIALS'
    ) TO reported-header.

    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Header BY \_Items
      FIELDS ( SerialNo Reject ReasonText )
      WITH VALUE #( ( %tky = ls_header-%tky ) )
      RESULT DATA(lt_items)
      FAILED DATA(ls_items_failed)
      REPORTED DATA(ls_items_reported).

    LOOP AT ls_items_reported-header
      INTO DATA(ls_items_header_msg).

      APPEND VALUE #(
        %tky = ls_items_header_msg-%tky
        %msg = ls_items_header_msg-%msg
      ) TO reported-header.

    ENDLOOP.

    LOOP AT ls_items_reported-item
      INTO DATA(ls_items_item_msg).

      APPEND VALUE #(
        %tky             = ls_items_item_msg-%tky
        %msg             = ls_items_item_msg-%msg
        %path-Header-%tky = ls_header-%tky
      ) TO reported-item.

    ENDLOOP.

    IF ls_items_failed IS NOT INITIAL.

      APPEND VALUE #(
        %tky = ls_header-%tky
      ) TO failed-header.

      APPEND VALUE #(
        %tky        = ls_header-%tky
        %state_area = 'VALIDATE_SERIALS'
        %msg = new_message(
            id       = 'ZLOAD_REJ_MSG'
            number   = '042'
            severity = if_abap_behv_message=>severity-error
          )
      ) TO reported-header.

      CONTINUE.

    ENDIF.

    DATA(lv_rejected_count) = 0.
    DATA(lv_missing_reason) = abap_false.

    LOOP AT lt_items INTO DATA(ls_item).

      "Reuse the existing state area to clear old code/reason errors
      APPEND VALUE #(
        %tky             = ls_item-%tky
        %state_area      = 'VALIDATE_REJECTION_CODE'
        %path-Header-%tky = ls_header-%tky
      ) TO reported-item.

      IF ls_item-Reject <> abap_true.
        CONTINUE.
      ENDIF.

      lv_rejected_count = lv_rejected_count + 1.

      "Only rejection reason is required
      IF ls_item-ReasonText IS INITIAL.

        lv_missing_reason = abap_true.

        APPEND VALUE #(
          %tky = ls_item-%tky
        ) TO failed-item.

        APPEND VALUE #(
          %tky                = ls_item-%tky
          %state_area         = 'VALIDATE_REJECTION_CODE'
          %element-ReasonText = if_abap_behv=>mk-on
          %path-Header-%tky    = ls_header-%tky
          %msg = new_message(
            id       = 'ZLOAD_REJ_MSG'
            number   = '043'
            severity = if_abap_behv_message=>severity-error
            v1       = |{ ls_item-SerialNo }|
          )
        ) TO reported-item.

      ENDIF.

    ENDLOOP.

    "Positive rejection quantity requires serial rows
    IF ls_header-LoadingRejQty > 0
       AND lt_items IS INITIAL.

      APPEND VALUE #(
        %tky = ls_header-%tky
      ) TO failed-header.

      APPEND VALUE #(
        %tky                   = ls_header-%tky
        %state_area            = 'VALIDATE_SERIALS'
        %element-LoadingRejQty = if_abap_behv=>mk-on
        %msg = new_message(
            id       = 'ZLOAD_REJ_MSG'
            number   = '044'
            severity = if_abap_behv_message=>severity-error
          )
      ) TO reported-header.

      CONTINUE.

    ENDIF.

    "Quantity must match the actual rejected serial count
    IF ls_header-LoadingRejQty <> lv_rejected_count.

      APPEND VALUE #(
        %tky = ls_header-%tky
      ) TO failed-header.

      APPEND VALUE #(
        %tky                   = ls_header-%tky
        %state_area            = 'VALIDATE_SERIALS'
        %element-LoadingRejQty = if_abap_behv=>mk-on
        %element-RejectedCount = if_abap_behv=>mk-on
        %msg = new_message(
            id       = 'ZLOAD_REJ_MSG'
            number   = '045'
            severity = if_abap_behv_message=>severity-error
            v1       = |{ ls_header-LoadingRejQty }|
            v2       = |{ lv_rejected_count }|
          )
      ) TO reported-header.

    ELSEIF lv_missing_reason = abap_true.

      APPEND VALUE #(
        %tky = ls_header-%tky
      ) TO failed-header.

    ENDIF.

  ENDLOOP.

ENDMETHOD.


  METHOD GetSerialLock.

  CLEAR rv_error.

  IF is_header-ProdOrder IS INITIAL
     OR is_item-SerialNo IS INITIAL.
    RETURN.
  ENDIF.

  DATA:
    lv_order          TYPE c LENGTH 12,
    lv_external_order TYPE c LENGTH 12.

  lv_order = is_header-ProdOrder.
  lv_order = |{ lv_order ALPHA = IN WIDTH = 12 }|.

  lv_external_order = |{ lv_order ALPHA = OUT }|.

  DATA(lv_serial) =
    condense( |{ is_item-SerialNo ALPHA = OUT }| ).

  "Read matching posted Confirmation serials
  "Cancelled confirmations and cancelled serials are excluded
  SELECT
    s~SerialNo,
    s~Material
    FROM ZI_ORDER_CONFIRMATION AS h
    INNER JOIN ZI_SERIAL_DISPOSITION AS s
      ON s~ConfirmId = h~ConfirmId
    WHERE ( h~OrderNo = @lv_order
         OR h~OrderNo = @lv_external_order )
      AND h~order_type = @is_header-OrderType
      AND h~batch_number = @is_header-BatchNumber
      AND ( h~Status = 'POSTED'
         OR h~Status = 'PART_POST' )
      AND ( s~Approved = @abap_true
         OR s~Rejected = @abap_true )
      AND s~CancelledSerialno <> @abap_true
    INTO TABLE @DATA(lt_posted).

  IF lt_posted IS INITIAL.
    RETURN.
  ENDIF.

  "Direct matching applies to ALL order types
  "Confirmation may hold the produced material rather than consumed material
  LOOP AT lt_posted INTO DATA(ls_posted).

    DATA(lv_posted_serial) =
      condense( |{ ls_posted-SerialNo ALPHA = OUT }| ).

    IF lv_posted_serial = lv_serial
       AND ( ls_posted-Material = is_item-Material
          OR ls_posted-Material = is_header-Material ).

      rv_error =
        VALUE ty_load_message( number = '025'
          v1 = |{ lv_serial }| ).

      RETURN.

    ENDIF.

  ENDLOOP.

  "Additional mapping for kiln orders with different serial numbers
  IF is_header-OrderType <> 'ZP07'
     AND is_header-OrderType <> 'YP07'.
    RETURN.
  ENDIF.

  SELECT
    GlazedSerialNo,
    KilnSerialNo,
    KilnMaterial,
    GlazedBatchNo
    FROM ZI_KILN_ITM
    WHERE GlazedMaterial = @is_item-Material
      AND KilnMaterial = @is_header-Material
      AND KilnBatchNo = @is_header-BatchNumber
    INTO TABLE @DATA(lt_mapping).

  DATA(lv_mapping_found) = abap_false.

  LOOP AT lt_mapping INTO DATA(ls_mapping).

    DATA(lv_glazed_serial) =
      condense( |{ ls_mapping-GlazedSerialNo ALPHA = OUT }| ).

    IF lv_glazed_serial <> lv_serial.
      CONTINUE.
    ENDIF.

    IF ls_mapping-KilnSerialNo IS INITIAL.
      CONTINUE.
    ENDIF.

    lv_mapping_found = abap_true.

    DATA(lv_kiln_serial) =
      condense( |{ ls_mapping-KilnSerialNo ALPHA = OUT }| ).

    LOOP AT lt_posted INTO ls_posted.

      lv_posted_serial =
        condense( |{ ls_posted-SerialNo ALPHA = OUT }| ).

      IF ls_posted-Material = ls_mapping-KilnMaterial
         AND lv_posted_serial = lv_kiln_serial.

        rv_error =
          VALUE ty_load_message( number = '026'
          v1 = |{ lv_serial }|
          v2 = |{ lv_kiln_serial }| ).

        RETURN.

      ENDIF.

    ENDLOOP.

  ENDLOOP.

  "Prevent editing when kiln correspondence cannot be verified
  IF lv_mapping_found = abap_false.

    rv_error =
      VALUE ty_load_message( number = '027'
          v1 = |{ lv_serial }| ).

  ENDIF.

ENDMETHOD.

  METHOD get_instance_features.
    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Header ALL FIELDS
      WITH CORRESPONDING #( keys )
      RESULT DATA(lt_headers).

    LOOP AT lt_headers INTO DATA(ls_header).
      READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
        ENTITY Header BY \_Items ALL FIELDS
        WITH VALUE #( ( %tky = ls_header-%tky ) )
        RESULT DATA(lt_items)
        FAILED DATA(ls_read_failed).

      DATA(lv_any_locked) = xsdbool( ls_read_failed IS NOT INITIAL ).
      DATA(lv_all_locked) = xsdbool( lt_items IS NOT INITIAL ).
      LOOP AT lt_items INTO DATA(ls_item).
        DATA(lv_error) = GetSerialLock(
          is_header = CORRESPONDING #( ls_header )
          is_item = CORRESPONDING #( ls_item ) ).
        IF lv_error IS INITIAL.
          lv_all_locked = abap_false.
        ELSE.
          lv_any_locked = abap_true.
        ENDIF.
      ENDLOOP.

      SELECT SINGLE HeaderUUID FROM ZI_LOAD_REJ_HDR
        WHERE HeaderUUID = @ls_header-HeaderUUID
        INTO @DATA(lv_active_uuid).
      DATA(lv_existing) = xsdbool( sy-subrc = 0 ).

      APPEND VALUE #(
        %tky = ls_header-%tky
        %field-ProdOrder = COND #(
          WHEN lv_existing = abap_true THEN if_abap_behv=>fc-f-read_only
          ELSE if_abap_behv=>fc-f-unrestricted )
        %delete = COND #(
          WHEN lv_any_locked = abap_true THEN if_abap_behv=>fc-o-disabled
          ELSE if_abap_behv=>fc-o-enabled )
        %action-Edit = COND #(
          WHEN lv_all_locked = abap_true OR ls_read_failed IS NOT INITIAL
          THEN if_abap_behv=>fc-o-disabled ELSE if_abap_behv=>fc-o-enabled )
        %action-Fetch = COND #(
          WHEN lv_any_locked = abap_true THEN if_abap_behv=>fc-o-disabled
          ELSE if_abap_behv=>fc-o-enabled )
        %action-FetchSerials = COND #(
          WHEN lv_any_locked = abap_true THEN if_abap_behv=>fc-o-disabled
          ELSE if_abap_behv=>fc-o-enabled )
      ) TO result.
    ENDLOOP.
  ENDMETHOD.

  METHOD ValidateOrderAndPosting.
    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Header ALL FIELDS
      WITH CORRESPONDING #( keys )
      RESULT DATA(lt_headers)
      FAILED DATA(ls_read_failed).
    LOOP AT ls_read_failed-header INTO DATA(ls_failed_header).
      APPEND VALUE #( %tky = ls_failed_header-%tky ) TO failed-header.
    ENDLOOP.

    LOOP AT lt_headers INTO DATA(ls_header).
      APPEND VALUE #( %tky = ls_header-%tky
        %state_area = 'ORDER_AND_POSTING' ) TO reported-header.
      DATA(lv_error) = VALUE ty_load_message( ).
      DATA lv_order TYPE c LENGTH 12.
      DATA lv_external_order TYPE c LENGTH 12.
      lv_order = ls_header-ProdOrder.
      lv_order = |{ lv_order ALPHA = IN WIDTH = 12 }|.
      lv_external_order = |{ lv_order ALPHA = OUT }|.

      IF ls_header-ProdOrder IS INITIAL OR ls_header-Plant IS INITIAL
         OR ls_header-OrderType IS INITIAL OR ls_header-Material IS INITIAL
         OR ls_header-WorkCenter IS INITIAL.
        lv_error = VALUE ty_load_message( number = '028' ).
      ELSE.
        SELECT SINGLE ProductionPlant, ManufacturingOrderType, Material, Batch

          FROM I_ManufacturingOrderItem
          WITH PRIVILEGED ACCESS
          WHERE ManufacturingOrder = @lv_order
            AND ManufacturingOrderItem = '0001'
          INTO @DATA(ls_order).
        IF sy-subrc <> 0.
          lv_error = VALUE ty_load_message( number = '029' ).
        ELSEIF ls_header-Plant <> ls_order-ProductionPlant
          OR ls_header-OrderType <> ls_order-ManufacturingOrderType
          OR ls_header-Material <> ls_order-Material
          OR ls_header-BatchNumber <> ls_order-Batch.
          lv_error = VALUE ty_load_message( number = '030' ).
        ENDIF.
      ENDIF.

      IF lv_error IS INITIAL.
        SELECT SINGLE HeaderUUID FROM ZI_LOAD_REJ_HDR
        WITH PRIVILEGED ACCESS
          WHERE HeaderUUID <> @ls_header-HeaderUUID
            AND ( ProdOrder = @lv_order OR ProdOrder = @lv_external_order )
          INTO @DATA(lv_duplicate).
        IF sy-subrc = 0.
          lv_error = VALUE ty_load_message( number = '031' ).
        ENDIF.
      ENDIF.

      "Detect duplicate new headers within the current save request too.
      IF lv_error IS INITIAL.
        LOOP AT lt_headers INTO DATA(ls_other).
          IF ls_other-HeaderUUID = ls_header-HeaderUUID.
            CONTINUE.
          ENDIF.
          DATA lv_other_order TYPE c LENGTH 12.
          lv_other_order = ls_other-ProdOrder.
          lv_other_order = |{ lv_other_order ALPHA = IN WIDTH = 12 }|.
          IF lv_other_order = lv_order.
            lv_error = VALUE ty_load_message( number = '032' ).
            EXIT.
          ENDIF.
        ENDLOOP.
      ENDIF.

      IF lv_error IS INITIAL.
        SELECT SINGLE * FROM ZI_LOAD_REJ_HDR
        WITH PRIVILEGED ACCESS
          WHERE HeaderUUID = @ls_header-HeaderUUID
          INTO @DATA(ls_active_header).
        IF sy-subrc = 0.
          DATA lv_old_order TYPE c LENGTH 12.
          lv_old_order = ls_active_header-ProdOrder.
          lv_old_order = |{ lv_old_order ALPHA = IN WIDTH = 12 }|.
          IF lv_old_order <> lv_order
             OR ls_header-OrderType <> ls_active_header-OrderType
             OR ls_header-Material <> ls_active_header-Material
             OR ls_header-BatchNumber <> ls_active_header-BatchNumber.
            lv_error = VALUE ty_load_message( number = '033' ).
          ENDIF.
        ENDIF.
      ENDIF.

      "Detect deletion of posted rows, including a draft opened before posting.
      IF lv_error IS INITIAL.
        READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
          ENTITY Header BY \_Items ALL FIELDS
          WITH VALUE #( ( %tky = ls_header-%tky ) )
          RESULT DATA(lt_items)
          FAILED DATA(ls_items_failed).
        IF ls_items_failed IS NOT INITIAL.
          lv_error = VALUE ty_load_message( number = '034' ).
        ELSE.
          SELECT * FROM ZI_LOAD_REJ_ITM
          WITH PRIVILEGED ACCESS
            WHERE HeaderUUID = @ls_header-HeaderUUID
            INTO TABLE @DATA(lt_active_items).
          LOOP AT lt_active_items INTO DATA(ls_active_item).
            IF line_exists( lt_items[ SerialNo = ls_active_item-SerialNo ] ).
              CONTINUE.
            ENDIF.
            lv_error = GetSerialLock(
              is_header = CORRESPONDING #( ls_header )
              is_item = ls_active_item ).
            IF lv_error IS NOT INITIAL.
              EXIT.
            ENDIF.
          ENDLOOP.
        ENDIF.
      ENDIF.

      IF lv_error IS NOT INITIAL.
        APPEND VALUE #( %tky = ls_header-%tky ) TO failed-header.
        APPEND VALUE #(
          %tky = ls_header-%tky
          %state_area = 'ORDER_AND_POSTING'
          %msg = new_message(
            id       = 'ZLOAD_REJ_MSG'
            number   = lv_error-number
            severity = if_abap_behv_message=>severity-error
            v1       = lv_error-v1
            v2       = lv_error-v2
            v3       = lv_error-v3
            v4       = lv_error-v4
          )
        ) TO reported-header.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

  METHOD precheck_delete.
    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Header ALL FIELDS WITH CORRESPONDING #( keys )
      RESULT DATA(lt_headers) FAILED DATA(ls_read_failed).
    LOOP AT ls_read_failed-header INTO DATA(ls_failed).
      APPEND VALUE #( %tky = ls_failed-%tky ) TO failed-header.
    ENDLOOP.
    LOOP AT lt_headers INTO DATA(ls_header).
      READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
        ENTITY Header BY \_Items ALL FIELDS
        WITH VALUE #( ( %tky = ls_header-%tky ) )
        RESULT DATA(lt_items) FAILED DATA(ls_items_failed).
      DATA(lv_error) = VALUE ty_load_message( ).
      IF ls_items_failed IS NOT INITIAL.
        lv_error = VALUE ty_load_message( number = '035' ).
      ELSE.
        LOOP AT lt_items INTO DATA(ls_item).
          lv_error = GetSerialLock(
            is_header = CORRESPONDING #( ls_header )
            is_item = CORRESPONDING #( ls_item ) ).
          IF lv_error IS NOT INITIAL.
            EXIT.
          ENDIF.
        ENDLOOP.
      ENDIF.
      IF lv_error IS NOT INITIAL.
        APPEND VALUE #( %tky = ls_header-%tky ) TO failed-header.
        APPEND VALUE #( %tky = ls_header-%tky
          %msg = new_message(
            id       = 'ZLOAD_REJ_MSG'
            number   = lv_error-number
            severity = if_abap_behv_message=>severity-error
            v1       = lv_error-v1
            v2       = lv_error-v2
            v3       = lv_error-v3
            v4       = lv_error-v4
          )
        ) TO reported-header.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

ENDCLASS.

CLASS lhc_item DEFINITION
  INHERITING FROM cl_abap_behavior_handler.

  PRIVATE SECTION.

    METHODS RejectAllItems FOR MODIFY
      IMPORTING keys FOR ACTION Item~RejectAllItems
      RESULT result.

    METHODS UnrejectAllItems FOR MODIFY
      IMPORTING keys FOR ACTION Item~UnrejectAllItems
      RESULT result.

      METHODS SetRejectionRemarks FOR DETERMINE ON MODIFY
  IMPORTING keys FOR Item~SetRejectionRemarks.

      METHODS get_instance_features
  FOR INSTANCE FEATURES
  keys REQUEST requested_features
  FOR Item RESULT result.


    METHODS ValidatePostedSerial FOR VALIDATE ON SAVE
      IMPORTING keys FOR Item~ValidatePostedSerial.
    METHODS precheck_update FOR PRECHECK
      IMPORTING entities FOR UPDATE Item.
    METHODS precheck_delete FOR PRECHECK
      IMPORTING keys FOR DELETE Item.

ENDCLASS.


CLASS lhc_item IMPLEMENTATION.

  METHOD RejectAllItems.

    "Find parent headers of the selected serial rows
    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Item BY \_Header
      ALL FIELDS
      WITH CORRESPONDING #( keys )
      RESULT DATA(lt_headers)
      FAILED DATA(ls_header_failed)
      REPORTED DATA(ls_header_reported).

    failed   = CORRESPONDING #( ls_header_failed ).
    reported = CORRESPONDING #( ls_header_reported ).

    IF lt_headers IS INITIAL.
      RETURN.
    ENDIF.

    "Read all serial rows belonging to those headers
    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Header BY \_Items
      ALL FIELDS
      WITH CORRESPONDING #( lt_headers )
      RESULT DATA(lt_items)
      FAILED DATA(ls_items_failed)
      REPORTED DATA(ls_items_reported).

    APPEND LINES OF ls_items_failed-header
      TO failed-header.
    APPEND LINES OF ls_items_failed-item
      TO failed-item.

    APPEND LINES OF ls_items_reported-header
      TO reported-header.
    APPEND LINES OF ls_items_reported-item
      TO reported-item.

    IF ls_items_failed IS NOT INITIAL.
      RETURN.
    ENDIF.


    "A bulk action must not modify any posted sibling serial.
    DATA(lv_posting_error) = VALUE ty_load_message( ).
    LOOP AT lt_items INTO DATA(ls_check_item).
      READ TABLE lt_headers INTO DATA(ls_check_header)
        WITH KEY HeaderUUID = ls_check_item-HeaderUUID
                 %is_draft = ls_check_item-%is_draft.
      IF sy-subrc <> 0.
        lv_posting_error = VALUE ty_load_message( number = '036' ).
      ELSE.
        lv_posting_error = lhc_header=>GetSerialLock(
          is_header = CORRESPONDING #( ls_check_header )
          is_item = CORRESPONDING #( ls_check_item ) ).
      ENDIF.
      IF lv_posting_error IS NOT INITIAL.
        EXIT.
      ENDIF.
    ENDLOOP.
    IF lv_posting_error IS NOT INITIAL.
      LOOP AT keys INTO DATA(ls_action_key).
        APPEND VALUE #( %tky = ls_action_key-%tky ) TO failed-item.
        APPEND VALUE #( %tky = ls_action_key-%tky
          %msg = new_message(
            id       = 'ZLOAD_REJ_MSG'
            number   = lv_posting_error-number
            severity = if_abap_behv_message=>severity-error
            v1       = lv_posting_error-v1
            v2       = lv_posting_error-v2
            v3       = lv_posting_error-v3
            v4       = lv_posting_error-v4
          )
        ) TO reported-item.
      ENDLOOP.
      RETURN.
    ENDIF.

    "Reject all serials; preserve existing codes and remarks
    MODIFY ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Item
      UPDATE FIELDS ( Reject )
      WITH VALUE #(
        FOR ls_item IN lt_items
        (
          %tky   = ls_item-%tky
          Reject = abap_true
        )
      )
      FAILED DATA(ls_update_failed)
      REPORTED DATA(ls_update_reported).

    APPEND LINES OF ls_update_failed-header
      TO failed-header.
    APPEND LINES OF ls_update_failed-item
      TO failed-item.

    APPEND LINES OF ls_update_reported-header
      TO reported-header.
    APPEND LINES OF ls_update_reported-item
      TO reported-item.

    IF ls_update_failed IS NOT INITIAL.
      RETURN.
    ENDIF.

    "Re-read actual item values before calculating the count
    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Header BY \_Items
      ALL FIELDS
      WITH CORRESPONDING #( lt_headers )
      RESULT DATA(lt_after)
      FAILED DATA(ls_after_failed)
      REPORTED DATA(ls_after_reported).

    APPEND LINES OF ls_after_failed-header
      TO failed-header.
    APPEND LINES OF ls_after_failed-item
      TO failed-item.

    APPEND LINES OF ls_after_reported-header
      TO reported-header.
    APPEND LINES OF ls_after_reported-item
      TO reported-item.

    IF ls_after_failed IS NOT INITIAL.
      RETURN.
    ENDIF.

    DATA lt_header_updates TYPE TABLE FOR UPDATE
      ZI_LOAD_REJ_HDR.

    LOOP AT lt_headers INTO DATA(ls_header).

      DATA(lv_count) = 0.

      LOOP AT lt_after INTO DATA(ls_after)
        WHERE HeaderUUID = ls_header-HeaderUUID
          AND %is_draft = ls_header-%is_draft
          AND Reject = abap_true.

        lv_count = lv_count + 1.

      ENDLOOP.

      APPEND VALUE #(
        %tky          = ls_header-%tky
        RejectedCount = lv_count
      ) TO lt_header_updates.

    ENDLOOP.

    MODIFY ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Header
      UPDATE FIELDS ( RejectedCount )
      WITH lt_header_updates
      FAILED DATA(ls_count_failed)
      REPORTED DATA(ls_count_reported).

    APPEND LINES OF ls_count_failed-header
      TO failed-header.
    APPEND LINES OF ls_count_failed-item
      TO failed-item.

    APPEND LINES OF ls_count_reported-header
      TO reported-header.
    APPEND LINES OF ls_count_reported-item
      TO reported-item.

    IF ls_count_failed IS NOT INITIAL.
      RETURN.
    ENDIF.

    "Return the originally selected serial rows
    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Item
      ALL FIELDS
      WITH CORRESPONDING #( keys )
      RESULT DATA(lt_result)
      FAILED DATA(ls_result_failed)
      REPORTED DATA(ls_result_reported).

    APPEND LINES OF ls_result_failed-item
      TO failed-item.
    APPEND LINES OF ls_result_reported-item
      TO reported-item.

    result = VALUE #(
      FOR ls_result IN lt_result
      (
        %tky   = ls_result-%tky
        %param = ls_result
      )
    ).

  ENDMETHOD.


  METHOD UnrejectAllItems.

    "Find parent headers of the selected serial rows
    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Item BY \_Header
      ALL FIELDS
      WITH CORRESPONDING #( keys )
      RESULT DATA(lt_headers)
      FAILED DATA(ls_header_failed)
      REPORTED DATA(ls_header_reported).

    failed   = CORRESPONDING #( ls_header_failed ).
    reported = CORRESPONDING #( ls_header_reported ).

    IF lt_headers IS INITIAL.
      RETURN.
    ENDIF.

    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Header BY \_Items
      ALL FIELDS
      WITH CORRESPONDING #( lt_headers )
      RESULT DATA(lt_items)
      FAILED DATA(ls_items_failed)
      REPORTED DATA(ls_items_reported).

    APPEND LINES OF ls_items_failed-header
      TO failed-header.
    APPEND LINES OF ls_items_failed-item
      TO failed-item.

    APPEND LINES OF ls_items_reported-header
      TO reported-header.
    APPEND LINES OF ls_items_reported-item
      TO reported-item.

    IF ls_items_failed IS NOT INITIAL.
      RETURN.
    ENDIF.


    "A bulk action must not modify any posted sibling serial.
    DATA(lv_posting_error) = VALUE ty_load_message( ).
    LOOP AT lt_items INTO DATA(ls_check_item).
      READ TABLE lt_headers INTO DATA(ls_check_header)
        WITH KEY HeaderUUID = ls_check_item-HeaderUUID
                 %is_draft = ls_check_item-%is_draft.
      IF sy-subrc <> 0.
        lv_posting_error = VALUE ty_load_message( number = '036' ).
      ELSE.
        lv_posting_error = lhc_header=>GetSerialLock(
          is_header = CORRESPONDING #( ls_check_header )
          is_item = CORRESPONDING #( ls_check_item ) ).
      ENDIF.
      IF lv_posting_error IS NOT INITIAL.
        EXIT.
      ENDIF.
    ENDLOOP.
    IF lv_posting_error IS NOT INITIAL.
      LOOP AT keys INTO DATA(ls_action_key).
        APPEND VALUE #( %tky = ls_action_key-%tky ) TO failed-item.
        APPEND VALUE #( %tky = ls_action_key-%tky
          %msg = new_message(
            id       = 'ZLOAD_REJ_MSG'
            number   = lv_posting_error-number
            severity = if_abap_behv_message=>severity-error
            v1       = lv_posting_error-v1
            v2       = lv_posting_error-v2
            v3       = lv_posting_error-v3
            v4       = lv_posting_error-v4
          )
        ) TO reported-item.
      ENDLOOP.
      RETURN.
    ENDIF.

    "Unreject all and clear rejection-specific values
    MODIFY ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Item
      UPDATE FIELDS (
        Reject
        RejCode
        ReasonText
        Remarks
      )
      WITH VALUE #(
        FOR ls_item IN lt_items
        (
          %tky       = ls_item-%tky
          Reject     = abap_false
          RejCode    = ''
          ReasonText = ''
          Remarks    = ''
        )
      )
      FAILED DATA(ls_update_failed)
      REPORTED DATA(ls_update_reported).

    APPEND LINES OF ls_update_failed-header
      TO failed-header.
    APPEND LINES OF ls_update_failed-item
      TO failed-item.

    APPEND LINES OF ls_update_reported-header
      TO reported-header.
    APPEND LINES OF ls_update_reported-item
      TO reported-item.

    IF ls_update_failed IS NOT INITIAL.
      RETURN.
    ENDIF.

    MODIFY ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Header
      UPDATE FIELDS ( RejectedCount )
      WITH VALUE #(
        FOR ls_header IN lt_headers
        (
          %tky          = ls_header-%tky
          RejectedCount = 0
        )
      )
      FAILED DATA(ls_count_failed)
      REPORTED DATA(ls_count_reported).

    APPEND LINES OF ls_count_failed-header
      TO failed-header.
    APPEND LINES OF ls_count_failed-item
      TO failed-item.

    APPEND LINES OF ls_count_reported-header
      TO reported-header.
    APPEND LINES OF ls_count_reported-item
      TO reported-item.

    IF ls_count_failed IS NOT INITIAL.
      RETURN.
    ENDIF.

    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Item
      ALL FIELDS
      WITH CORRESPONDING #( keys )
      RESULT DATA(lt_result)
      FAILED DATA(ls_result_failed)
      REPORTED DATA(ls_result_reported).

    APPEND LINES OF ls_result_failed-item
      TO failed-item.
    APPEND LINES OF ls_result_reported-item
      TO reported-item.

    result = VALUE #(
      FOR ls_result IN lt_result
      (
        %tky   = ls_result-%tky
        %param = ls_result
      )
    ).

  ENDMETHOD.

  METHOD SetRejectionRemarks.

  READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
    ENTITY Item
    FIELDS ( Reject Remarks )
    WITH CORRESPONDING #( keys )
    RESULT DATA(lt_items)
    FAILED DATA(ls_read_failed)
    REPORTED DATA(ls_read_reported).

  "Copy messages individually to avoid structure conversion errors
  LOOP AT ls_read_reported-header INTO DATA(ls_read_header_message).

    APPEND VALUE #(
      %tky = ls_read_header_message-%tky
      %msg = ls_read_header_message-%msg
    ) TO reported-header.

  ENDLOOP.

  LOOP AT ls_read_reported-item INTO DATA(ls_read_item_message).

    APPEND VALUE #(
      %tky = ls_read_item_message-%tky
      %msg = ls_read_item_message-%msg
    ) TO reported-item.

  ENDLOOP.

  IF ls_read_failed IS NOT INITIAL.
    RETURN.
  ENDIF.

  DATA lt_updates TYPE TABLE FOR UPDATE ZI_LOAD_REJ_ITM.

  LOOP AT lt_items INTO DATA(ls_item).

    IF ls_item-Reject = abap_true.

      "Set the default only when remarks are blank
      IF ls_item-Remarks IS INITIAL.

        APPEND VALUE #(
          %tky    = ls_item-%tky
          Remarks = 'Loading Rejection'
        ) TO lt_updates.

      ENDIF.

    ELSE.

      "Clear the automatic default when Reject is unticked
      "Preserve any different remarks entered by the user
      IF ls_item-Remarks = 'Loading Rejection'.

        APPEND VALUE #(
          %tky    = ls_item-%tky
          Remarks = ''
        ) TO lt_updates.

      ENDIF.

    ENDIF.

  ENDLOOP.

  IF lt_updates IS INITIAL.
    RETURN.
  ENDIF.

  MODIFY ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
    ENTITY Item
    UPDATE FIELDS ( Remarks )
    WITH lt_updates
    FAILED DATA(ls_update_failed)
    REPORTED DATA(ls_update_reported).

  LOOP AT ls_update_reported-header INTO DATA(ls_header_message).

    APPEND VALUE #(
      %tky = ls_header_message-%tky
      %msg = ls_header_message-%msg
    ) TO reported-header.

  ENDLOOP.

  LOOP AT ls_update_reported-item INTO DATA(ls_item_message).

    APPEND VALUE #(
      %tky = ls_item_message-%tky
      %msg = ls_item_message-%msg
    ) TO reported-item.

  ENDLOOP.

  LOOP AT ls_update_failed-item INTO DATA(ls_failed_item).

    APPEND VALUE #(
      %tky = ls_failed_item-%tky
      %msg = new_message(
            id       = 'ZLOAD_REJ_MSG'
            number   = '046'
            severity = if_abap_behv_message=>severity-error
          )
    ) TO reported-item.

  ENDLOOP.

ENDMETHOD.

  METHOD get_instance_features.
    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Item ALL FIELDS WITH CORRESPONDING #( keys )
      RESULT DATA(lt_items).
    LOOP AT lt_items INTO DATA(ls_item).
      READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
        ENTITY Item BY \_Header ALL FIELDS
        WITH VALUE #( ( %tky = ls_item-%tky ) )
        RESULT DATA(lt_headers).
      DATA(lv_locked) = abap_true.
      DATA(lv_bulk_locked) = abap_true.
      IF lt_headers IS NOT INITIAL.
        DATA(ls_header) = lt_headers[ 1 ].
        lv_locked = xsdbool( lhc_header=>GetSerialLock(
          is_header = CORRESPONDING #( ls_header )
          is_item = CORRESPONDING #( ls_item ) ) IS NOT INITIAL ).
        READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
          ENTITY Header BY \_Items ALL FIELDS
          WITH VALUE #( ( %tky = ls_header-%tky ) )
          RESULT DATA(lt_siblings) FAILED DATA(ls_sibling_failed).
        lv_bulk_locked = xsdbool( ls_sibling_failed IS NOT INITIAL ).
        LOOP AT lt_siblings INTO DATA(ls_sibling).
          IF lhc_header=>GetSerialLock(
            is_header = CORRESPONDING #( ls_header )
            is_item = CORRESPONDING #( ls_sibling ) ) IS NOT INITIAL.
            lv_bulk_locked = abap_true.
            EXIT.
          ENDIF.
        ENDLOOP.
      ENDIF.

      APPEND VALUE #(
        %tky = ls_item-%tky
        %update = COND #( WHEN lv_locked = abap_true
          THEN if_abap_behv=>fc-o-disabled ELSE if_abap_behv=>fc-o-enabled )
        %delete = COND #( WHEN lv_locked = abap_true
          THEN if_abap_behv=>fc-o-disabled ELSE if_abap_behv=>fc-o-enabled )
        %field-Reject = COND #( WHEN lv_locked = abap_true
          THEN if_abap_behv=>fc-f-read_only ELSE if_abap_behv=>fc-f-unrestricted )
        %field-Remarks = COND #( WHEN lv_locked = abap_true
          THEN if_abap_behv=>fc-f-read_only ELSE if_abap_behv=>fc-f-unrestricted )
        %field-ReasonText = COND #(
          WHEN lv_locked = abap_false AND ls_item-Reject = abap_true
          THEN if_abap_behv=>fc-f-unrestricted ELSE if_abap_behv=>fc-f-read_only )
        %action-RejectAllItems = COND #( WHEN lv_bulk_locked = abap_true
          THEN if_abap_behv=>fc-o-disabled ELSE if_abap_behv=>fc-o-enabled )
        %action-UnrejectAllItems = COND #( WHEN lv_bulk_locked = abap_true
          THEN if_abap_behv=>fc-o-disabled ELSE if_abap_behv=>fc-o-enabled )
      ) TO result.
    ENDLOOP.
  ENDMETHOD.


  METHOD ValidatePostedSerial.
    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Item ALL FIELDS WITH CORRESPONDING #( keys )
      RESULT DATA(lt_items) FAILED DATA(ls_read_failed).
    LOOP AT ls_read_failed-item INTO DATA(ls_failed).
      APPEND VALUE #( %tky = ls_failed-%tky ) TO failed-item.
    ENDLOOP.
    LOOP AT lt_items INTO DATA(ls_item).
      APPEND VALUE #( %tky = ls_item-%tky
        %state_area = 'CONFIRMATION_LOCK'
        %path-Header-%tky = VALUE #(
          HeaderUUID = ls_item-HeaderUUID %is_draft = ls_item-%is_draft )
      ) TO reported-item.
      READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
        ENTITY Item BY \_Header ALL FIELDS
        WITH VALUE #( ( %tky = ls_item-%tky ) )
        RESULT DATA(lt_headers).
      DATA(lv_error) = VALUE ty_load_message( ).
      IF lt_headers IS INITIAL.
        lv_error = VALUE ty_load_message( number = '037' ).
      ELSE.
        DATA(ls_header) = lt_headers[ 1 ].
        lv_error = lhc_header=>GetSerialLock(
          is_header = CORRESPONDING #( ls_header )
          is_item = CORRESPONDING #( ls_item ) ).
        IF lv_error IS NOT INITIAL.
          "An unchanged saved posted row may remain in the record.
          SELECT SINGLE * FROM ZI_LOAD_REJ_ITM
          WITH PRIVILEGED ACCESS
            WHERE HeaderUUID = @ls_item-HeaderUUID AND SerialNo = @ls_item-SerialNo
            INTO @DATA(ls_active).
          IF sy-subrc = 0.
            IF ls_active-Reject = ls_item-Reject
               AND ls_active-ReasonText = ls_item-ReasonText
               AND ls_active-Remarks = ls_item-Remarks
               AND ls_active-RejCode = ls_item-RejCode
               AND ls_active-Material = ls_item-Material
               AND ls_active-OrderType = ls_item-OrderType
               AND ls_active-Stage = ls_item-Stage.
              CLEAR lv_error.
            ENDIF.
          ELSEIF ls_item-Reject = abap_false
             AND ls_item-ReasonText IS INITIAL AND ls_item-Remarks IS INITIAL
             AND ls_item-RejCode IS INITIAL.
            "New neutral rows can be displayed without modifying a posting.
            CLEAR lv_error.
          ENDIF.
        ENDIF.
      ENDIF.
      IF lv_error IS NOT INITIAL.
        APPEND VALUE #( %tky = ls_item-%tky ) TO failed-item.
        APPEND VALUE #(
          %tky = ls_item-%tky %state_area = 'CONFIRMATION_LOCK'
          %path-Header-%tky = VALUE #(
            HeaderUUID = ls_item-HeaderUUID %is_draft = ls_item-%is_draft )
          %element-Reject = if_abap_behv=>mk-on
          %element-ReasonText = if_abap_behv=>mk-on
          %element-Remarks = if_abap_behv=>mk-on
          %msg = new_message(
            id       = 'ZLOAD_REJ_MSG'
            number   = lv_error-number
            severity = if_abap_behv_message=>severity-error
            v1       = lv_error-v1
            v2       = lv_error-v2
            v3       = lv_error-v3
            v4       = lv_error-v4
          )
        ) TO reported-item.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

  METHOD precheck_update.
    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Item ALL FIELDS WITH CORRESPONDING #( entities )
      RESULT DATA(lt_items) FAILED DATA(ls_read_failed).
    LOOP AT ls_read_failed-item INTO DATA(ls_failed).
      APPEND VALUE #( %tky = ls_failed-%tky ) TO failed-item.
    ENDLOOP.
    LOOP AT lt_items INTO DATA(ls_item).
      READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
        ENTITY Item BY \_Header ALL FIELDS
        WITH VALUE #( ( %tky = ls_item-%tky ) )
        RESULT DATA(lt_headers).
      DATA(lv_error) = VALUE ty_load_message( ).
      IF lt_headers IS INITIAL.
        lv_error = VALUE ty_load_message( number = '036' ).
      ELSE.
        lv_error = lhc_header=>GetSerialLock(
          is_header = CORRESPONDING #( lt_headers[ 1 ] )
          is_item = CORRESPONDING #( ls_item ) ).
      ENDIF.
      IF lv_error IS NOT INITIAL.
        APPEND VALUE #( %tky = ls_item-%tky ) TO failed-item.
        APPEND VALUE #( %tky = ls_item-%tky
          %msg = new_message(
            id       = 'ZLOAD_REJ_MSG'
            number   = lv_error-number
            severity = if_abap_behv_message=>severity-error
            v1       = lv_error-v1
            v2       = lv_error-v2
            v3       = lv_error-v3
            v4       = lv_error-v4
          )
        ) TO reported-item.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

  METHOD precheck_delete.
    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
      ENTITY Item ALL FIELDS WITH CORRESPONDING #( keys )
      RESULT DATA(lt_items) FAILED DATA(ls_read_failed).
    LOOP AT ls_read_failed-item INTO DATA(ls_failed).
      APPEND VALUE #( %tky = ls_failed-%tky ) TO failed-item.
    ENDLOOP.
    LOOP AT lt_items INTO DATA(ls_item).
      READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
        ENTITY Item BY \_Header ALL FIELDS
        WITH VALUE #( ( %tky = ls_item-%tky ) )
        RESULT DATA(lt_headers).
      DATA(lv_error) = VALUE ty_load_message( ).
      IF lt_headers IS INITIAL.
        lv_error = VALUE ty_load_message( number = '036' ).
      ELSE.
        lv_error = lhc_header=>GetSerialLock(
          is_header = CORRESPONDING #( lt_headers[ 1 ] )
          is_item = CORRESPONDING #( ls_item ) ).
      ENDIF.
      IF lv_error IS NOT INITIAL.
        APPEND VALUE #( %tky = ls_item-%tky ) TO failed-item.
        APPEND VALUE #( %tky = ls_item-%tky
          %msg = new_message(
            id       = 'ZLOAD_REJ_MSG'
            number   = lv_error-number
            severity = if_abap_behv_message=>severity-error
            v1       = lv_error-v1
            v2       = lv_error-v2
            v3       = lv_error-v3
            v4       = lv_error-v4
          )
        ) TO reported-item.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

ENDCLASS.





*CLASS lhc_header DEFINITION
*  INHERITING FROM cl_abap_behavior_handler.
*
*  PRIVATE SECTION.
*
*    METHODS get_instance_authorizations
*      FOR INSTANCE AUTHORIZATION
*      keys REQUEST requested_authorizations
*      FOR Header RESULT result.
*
*    METHODS get_global_authorizations
*      FOR GLOBAL AUTHORIZATION
*      REQUEST requested_authorizations
*      FOR Header RESULT result.
*
*    METHODS Fetch FOR MODIFY
*      IMPORTING keys FOR ACTION Header~Fetch
*      RESULT result.
*
*      METHODS FetchSerials FOR MODIFY
*  IMPORTING keys FOR ACTION Header~FetchSerials
*  RESULT result.
*
*    METHODS ValidateSerials FOR VALIDATE ON SAVE
*      IMPORTING keys FOR Header~ValidateSerials.
*ENDCLASS.
*
*
*CLASS lhc_header IMPLEMENTATION.
*
*  METHOD get_instance_authorizations.
*
*    "Development permissions: replace with actual checks.
*    result = VALUE #(
*      FOR key IN keys
*      (
*        %tky    = key-%tky
*        %update = if_abap_behv=>auth-allowed
*        %delete = if_abap_behv=>auth-allowed
*      )
*    ).
*
*  ENDMETHOD.
*
*
*  METHOD get_global_authorizations.
*
*    result-%create = if_abap_behv=>auth-allowed.
*
*  ENDMETHOD.
*
*
* METHOD Fetch.
*
*  DATA:
*    lv_order         TYPE c LENGTH 12,
*    lv_item_order    TYPE c LENGTH 12,
*    lv_work_center   TYPE c LENGTH 8,
*    lv_error         TYPE string,
*    lv_loaded_qty    TYPE p LENGTH 16 DECIMALS 3,
*    lv_rejection_qty TYPE p LENGTH 16 DECIMALS 3,
*    lv_quantity_unit TYPE c LENGTH 3,
*    lv_confirmed     TYPE abap_bool,
*    lv_has_quantity  TYPE abap_bool.
*
*  READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*    ENTITY Header
*    ALL FIELDS
*    WITH CORRESPONDING #( keys )
*    RESULT DATA(lt_headers)
*    FAILED DATA(ls_read_failed)
*    REPORTED DATA(ls_read_reported).
*
*  failed   = CORRESPONDING #( ls_read_failed ).
*  reported = CORRESPONDING #( ls_read_reported ).
*
*  LOOP AT lt_headers INTO DATA(ls_header).
*
*    CLEAR:
*      lv_order,
*      lv_item_order,
*      lv_work_center,
*      lv_error,
*      lv_loaded_qty,
*      lv_rejection_qty,
*      lv_quantity_unit,
*      lv_confirmed,
*      lv_has_quantity.
*
*    "1. Check draft and entered order number
*    IF ls_header-%is_draft <> if_abap_behv=>mk-on.
*
*      lv_error = 'Choose Edit before fetching order details'.
*
*    ELSEIF ls_header-ProdOrder IS INITIAL.
*
*      lv_error = 'Enter an order number'.
*
*    ENDIF.
*
*    "2. Convert the order number and read order details
*    IF lv_error IS INITIAL.
*
*      lv_order = ls_header-ProdOrder.
*      lv_order = |{ lv_order ALPHA = IN WIDTH = 12 }|.
*
*      SELECT SINGLE
*        ManufacturingOrder,
*        ManufacturingOrderType,
*        ProductionPlant,
*        Material,
*        Batch,
*        ProductionUnit,
*        OrderIsReleased,
*        IsMarkedForDeletion
*        FROM I_ManufacturingOrderItem
*        WHERE ManufacturingOrder = @lv_order
*          AND ManufacturingOrderItem = '0001'
*        INTO @DATA(ls_order).
*
*      IF sy-subrc <> 0.
*
*        lv_error = 'Order not found or not accessible'.
*
*      ELSEIF ls_order-IsMarkedForDeletion IS NOT INITIAL.
*
*        lv_error = 'Order is marked for deletion'.
*
*      ELSEIF ls_order-OrderIsReleased IS INITIAL.
*
*        lv_error = 'Order is not released'.
*
*      ENDIF.
*
*    ENDIF.
*
*    "3. Check active system statuses
*    IF lv_error IS INITIAL.
*
*      SELECT StatusCode
*        FROM I_ManufacturingOrderStatus
*        WHERE ManufacturingOrder = @lv_order
*          AND StatusIsActive = @abap_true
*          AND IsUserStatus = @abap_false
*        INTO TABLE @DATA(lt_status).
*
*      IF lt_status IS INITIAL.
*
*        lv_error = 'Order status could not be verified'.
*
*      ELSEIF line_exists(
*        lt_status[ StatusCode = 'I0045' ] )
*        OR line_exists(
*        lt_status[ StatusCode = 'I0046' ] ).
*
*        lv_error = 'Order is technically completed or closed'.
*
*      ELSEIF NOT line_exists(
*        lt_status[ StatusCode = 'I0002' ] ).
*
*        lv_error = 'Order is not released'.
*
*      ELSE.
*
*        lv_confirmed = xsdbool(
*          line_exists( lt_status[ StatusCode = 'I0009' ] )
*          OR
*          line_exists( lt_status[ StatusCode = 'I0010' ] )
*        ).
*
*      ENDIF.
*
*    ENDIF.
*
*    "4. Check that existing serials belong to this order
*    IF lv_error IS INITIAL.
*
*      READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*        ENTITY Header BY \_Items
*        FIELDS ( ProdOrder )
*        WITH VALUE #( ( %tky = ls_header-%tky ) )
*        RESULT DATA(lt_items)
*        FAILED DATA(ls_items_failed)
*        REPORTED DATA(ls_items_reported).
*
*      APPEND LINES OF ls_items_reported-header
*        TO reported-header.
*
*      APPEND LINES OF ls_items_reported-item
*        TO reported-item.
*
*      IF ls_items_failed IS NOT INITIAL.
*
*        lv_error = 'Existing serials could not be checked'.
*
*      ELSE.
*
*        LOOP AT lt_items INTO DATA(ls_item).
*
*          lv_item_order = ls_item-ProdOrder.
*          lv_item_order =
*            |{ lv_item_order ALPHA = IN WIDTH = 12 }|.
*
*          IF lv_item_order <> lv_order.
*
*            lv_error =
*              'Order changed: discard this draft and create a new one'.
*
*            EXIT.
*
*          ENDIF.
*
*        ENDLOOP.
*
*      ENDIF.
*
*    ENDIF.
*
*    "5. Fetch movement quantities using OrderID
*    IF lv_error IS INITIAL.
*
*      SELECT
*        MaterialDocumentYear,
*        MaterialDocument,
*        MaterialDocumentItem,
*        Material,
*        Batch,
*        GoodsMovementType,
*        QuantityInBaseUnit,
*        MaterialBaseUnit,
*        ReversedMaterialDocumentYear,
*        ReversedMaterialDocument,
*        ReversedMaterialDocumentItem
*        FROM I_MaterialDocumentItem_2
*        WHERE OrderID = @lv_order
*          AND ( GoodsMovementType = '261'
*             OR GoodsMovementType = '262'
*             OR GoodsMovementType = '531'
*              OR GoodsMovementType = '532' )
*        INTO TABLE @DATA(lt_quantity_movements).
*
*      LOOP AT lt_quantity_movements
*        INTO DATA(ls_quantity_movement).
*
*        "262 is used to identify reversed 261 documents
*        IF ls_quantity_movement-GoodsMovementType = '262'.
*          CONTINUE.
*        ENDIF.
*
*        IF ls_quantity_movement-GoodsMovementType = '261'.
*
*          IF ls_quantity_movement-ReversedMaterialDocument
*             IS NOT INITIAL.
*            CONTINUE.
*          ENDIF.
*
*          "Exclude the original 261 item referenced by a 262
*          IF line_exists(
*            lt_quantity_movements[
*              GoodsMovementType = '262'
*              ReversedMaterialDocumentYear =
*                ls_quantity_movement-MaterialDocumentYear
*              ReversedMaterialDocument =
*                ls_quantity_movement-MaterialDocument
*              ReversedMaterialDocumentItem =
*                ls_quantity_movement-MaterialDocumentItem
*            ]
*          ).
*            CONTINUE.
*          ENDIF.
*
*        ENDIF.
*
*        IF ls_quantity_movement-MaterialBaseUnit IS INITIAL.
*
*          lv_error = 'Material document quantity unit is missing'.
*          EXIT.
*
*        ENDIF.
*
*        IF lv_quantity_unit IS INITIAL.
*
*          lv_quantity_unit =
*            ls_quantity_movement-MaterialBaseUnit.
*
*        ELSEIF lv_quantity_unit
*               <> ls_quantity_movement-MaterialBaseUnit.
*
*          lv_error =
*            'Different movement units found; unit conversion required'.
*
*          EXIT.
*
*        ENDIF.
*
*        lv_has_quantity = abap_true.
*
*        CASE ls_quantity_movement-GoodsMovementType.
*
*  WHEN '261'.
*    lv_loaded_qty =
*      lv_loaded_qty
*      + abs( ls_quantity_movement-QuantityInBaseUnit ).
*
*  WHEN '531'.
*    lv_rejection_qty =
*      lv_rejection_qty
*      + abs( ls_quantity_movement-QuantityInBaseUnit ).
*
*  WHEN '532'.
*    lv_rejection_qty =
*      lv_rejection_qty
*      - abs( ls_quantity_movement-QuantityInBaseUnit ).
*
*ENDCASE.
*
*      ENDLOOP.
*
*      IF lv_quantity_unit IS INITIAL.
*        lv_quantity_unit = ls_order-ProductionUnit.
*      ENDIF.
*
*    ENDIF.
*
*    "6. Fetch Work Center from manufacturing order operations
*    IF lv_error IS INITIAL.
*
*      SELECT DISTINCT
*        wc~WorkCenter
*        FROM I_ManufacturingOrderOperation AS op
*        INNER JOIN I_WorkCenter AS wc
*          ON wc~WorkCenterInternalID = op~WorkCenterInternalID
*        WHERE op~ManufacturingOrder = @lv_order
*        INTO TABLE @DATA(lt_work_centers).
*
*      DELETE lt_work_centers WHERE WorkCenter IS INITIAL.
*
*      IF lt_work_centers IS INITIAL.
*
*        lv_error = 'Work center not found for this order'.
*
*      ELSEIF lines( lt_work_centers ) > 1.
*
*        lv_error =
*          'Multiple work centers found. Select the relevant operation or use loading configuration'.
*
*      ELSE.
*
*        lv_work_center = lt_work_centers[ 1 ]-WorkCenter.
*
*      ENDIF.
*
*    ENDIF.
*
*    "7. Report errors before updating the draft
*    IF lv_error IS NOT INITIAL.
*
*      APPEND VALUE #(
*        %tky = ls_header-%tky
*      ) TO failed-header.
*
*      APPEND VALUE #(
*        %tky = ls_header-%tky
*        %msg = new_message_with_text(
*          severity = if_abap_behv_message=>severity-error
*          text     = lv_error
*        )
*      ) TO reported-header.
*
*      CONTINUE.
*
*    ENDIF.
*
*    "8. Update the draft with fetched values
*    MODIFY ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*      ENTITY Header
*      UPDATE FIELDS (
*        ProdOrder
*        Plant
*        OrderType
*        WorkCenter
*        Material
*        BatchNumber
*        QuantityUnit
*        displayunit
*        LoadedQty
*        LoadingRejQty
*      )
*      WITH VALUE #(
*        (
*          %tky          = ls_header-%tky
*          ProdOrder     = ls_header-ProdOrder
*          Plant         = ls_order-ProductionPlant
*          OrderType     = ls_order-ManufacturingOrderType
*          WorkCenter    = lv_work_center
*          Material      = ls_order-Material
*          BatchNumber   = ls_order-Batch
*          QuantityUnit  = lv_quantity_unit
*          displayunit   = COND #(
*            WHEN lv_quantity_unit = 'ST'
*            THEN 'PC'
*            ELSE lv_quantity_unit
*          )
*          LoadedQty     = lv_loaded_qty
*          LoadingRejQty = lv_rejection_qty
*        )
*      )
*      FAILED DATA(ls_update_failed)
*      REPORTED DATA(ls_update_reported).
*
*    APPEND LINES OF ls_update_failed-header
*      TO failed-header.
*
*    APPEND LINES OF ls_update_reported-header
*      TO reported-header.
*
*    IF ls_update_failed IS NOT INITIAL.
*      CONTINUE.
*    ENDIF.
*
*    IF lv_confirmed = abap_true.
*
*      APPEND VALUE #(
*        %tky = ls_header-%tky
*        %msg = new_message_with_text(
*          severity = if_abap_behv_message=>severity-warning
*          text = 'Order confirmed: use these details for display only'
*        )
*      ) TO reported-header.
*
*    ENDIF.
*
*    IF lv_has_quantity = abap_false.
*
*      APPEND VALUE #(
*        %tky = ls_header-%tky
*        %msg = new_message_with_text(
*          severity = if_abap_behv_message=>severity-information
*          text = 'No unreversed 261 or 531 quantities found'
*        )
*      ) TO reported-header.
*
*    ENDIF.
*
*    "9. Return the refreshed header
*    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*      ENTITY Header
*      ALL FIELDS
*      WITH VALUE #( ( %tky = ls_header-%tky ) )
*      RESULT DATA(lt_updated)
*      FAILED DATA(ls_return_failed)
*      REPORTED DATA(ls_return_reported).
*
*    APPEND LINES OF ls_return_failed-header
*      TO failed-header.
*
*    APPEND LINES OF ls_return_reported-header
*      TO reported-header.
*
*    LOOP AT lt_updated INTO DATA(ls_updated).
*
*      APPEND VALUE #(
*        %tky   = ls_updated-%tky
*        %param = ls_updated
*      ) TO result.
*
*    ENDLOOP.
*
*  ENDLOOP.
*
*ENDMETHOD.
*
* METHOD FetchSerials.
*
*  TYPES:
*    BEGIN OF ty_balance,
*      material  TYPE c LENGTH 40,
*      serial_no TYPE c LENGTH 30,
*      balance   TYPE i,
*    END OF ty_balance,
*
*    tt_balances TYPE SORTED TABLE OF ty_balance
*      WITH UNIQUE KEY material serial_no,
*
*    ty_serial_key TYPE c LENGTH 30,
*
*    tt_serial_keys TYPE SORTED TABLE OF ty_serial_key
*      WITH UNIQUE KEY table_line.
*
*  DATA:
*    lv_order          TYPE c LENGTH 12,
*    lv_existing_order TYPE c LENGTH 12,
*    lv_error          TYPE string,
*    lv_index          TYPE i,
*    lv_rejected_count TYPE i,
*    lt_balances       TYPE tt_balances,
*    lt_serial_keys    TYPE tt_serial_keys.
*
*  DATA lt_create TYPE TABLE FOR CREATE
*    ZI_LOAD_REJ_HDR\_Items.
*
*  READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*    ENTITY Header
*    ALL FIELDS
*    WITH CORRESPONDING #( keys )
*    RESULT DATA(lt_headers)
*    FAILED DATA(ls_read_failed)
*    REPORTED DATA(ls_read_reported).
*
*  failed   = CORRESPONDING #( ls_read_failed ).
*  reported = CORRESPONDING #( ls_read_reported ).
*
*  LOOP AT lt_headers INTO DATA(ls_header).
*
*    CLEAR:
*      lv_order,
*      lv_existing_order,
*      lv_error,
*      lv_index,
*      lv_rejected_count,
*      lt_balances,
*      lt_serial_keys,
*      lt_create.
*
*    "1. Check current draft and order details
*    IF ls_header-%is_draft <> if_abap_behv=>mk-on.
*
*      lv_error = 'Choose Edit before fetching serial numbers'.
*
*    ELSEIF ls_header-ProdOrder IS INITIAL.
*
*      lv_error = 'Enter an order number'.
*
*    ELSEIF ls_header-Plant IS INITIAL.
*
*      lv_error = 'Click Fetch Order Data first'.
*
*    ENDIF.
*
*    IF lv_error IS INITIAL.
*
*      lv_order = ls_header-ProdOrder.
*      lv_order = |{ lv_order ALPHA = IN WIDTH = 12 }|.
*
*      SELECT SINGLE
*        ProductionPlant,
*        ManufacturingOrderType,
*        Material,
*        OrderIsReleased,
*        IsMarkedForDeletion
*        FROM I_ManufacturingOrderItem
*        WHERE ManufacturingOrder = @lv_order
*          AND ManufacturingOrderItem = '0001'
*        INTO @DATA(ls_order).
*
*      IF sy-subrc <> 0.
*
*        lv_error = 'Order not found or not accessible'.
*
*      ELSEIF ls_order-IsMarkedForDeletion IS NOT INITIAL.
*
*        lv_error = 'Order is marked for deletion'.
*
*      ELSEIF ls_order-OrderIsReleased IS INITIAL.
*
*        lv_error = 'Order is not released'.
*
*      ELSEIF ls_header-Plant <> ls_order-ProductionPlant
*        OR ls_header-OrderType <> ls_order-ManufacturingOrderType
*        OR ls_header-Material <> ls_order-Material.
*
*        lv_error = 'Order details changed. Click Fetch Order Data first'.
*
*      ENDIF.
*
*    ENDIF.
*
*    "2. Recheck current order status
*    IF lv_error IS INITIAL.
*
*      SELECT StatusCode
*        FROM I_ManufacturingOrderStatus
*        WHERE ManufacturingOrder = @lv_order
*          AND StatusIsActive = @abap_true
*          AND IsUserStatus = @abap_false
*        INTO TABLE @DATA(lt_status).
*
*      IF lt_status IS INITIAL.
*
*        lv_error = 'Order status could not be verified'.
*
*      ELSEIF line_exists(
*        lt_status[ StatusCode = 'I0045' ] )
*        OR line_exists(
*        lt_status[ StatusCode = 'I0046' ] ).
*
*        lv_error = 'Order is technically completed or closed'.
*
*      ELSEIF NOT line_exists(
*        lt_status[ StatusCode = 'I0002' ] ).
*
*        lv_error = 'Order is not released'.
*
*      ELSEIF line_exists(
*        lt_status[ StatusCode = 'I0009' ] )
*        OR line_exists(
*        lt_status[ StatusCode = 'I0010' ] ).
*
*        APPEND VALUE #(
*          %tky = ls_header-%tky
*          %msg = new_message_with_text(
*            severity = if_abap_behv_message=>severity-warning
*            text = 'Order confirmed: fetched serials are for display only'
*          )
*        ) TO reported-header.
*
*      ENDIF.
*
*    ENDIF.
*
*    "3. NEW CHECK: consumption material document must exist
*    IF lv_error IS INITIAL.
*
*      SELECT SINGLE MaterialDocument
*        FROM I_MaterialDocumentItem_2
*        WHERE OrderID = @lv_order
*          AND GoodsMovementType = '261'
*        INTO @DATA(lv_consumption_document).
*
*      IF sy-subrc <> 0.
*        lv_error = 'Consumption Not Posted'.
*      ENDIF.
*
*    ENDIF.
*
*    "4. Read serial movement history
*    IF lv_error IS INITIAL.
*
*      SELECT DISTINCT
*        doc~MaterialDocumentYear,
*        doc~MaterialDocument,
*        doc~MaterialDocumentItem,
*        doc~GoodsMovementType,
*        serial~Material,
*        serial~SerialNumber
*        FROM I_MaterialDocumentItem_2 AS doc
*        INNER JOIN I_SerialNumberMaterialDoc_2 AS serial
*          ON serial~MaterialDocumentYear =
*               doc~MaterialDocumentYear
*         AND serial~MaterialDocument =
*               doc~MaterialDocument
*         AND serial~MaterialDocumentItem =
*               doc~MaterialDocumentItem
*        WHERE doc~OrderID = @lv_order
*          AND ( doc~GoodsMovementType = '261'
*             OR doc~GoodsMovementType = '262' )
*        INTO TABLE @DATA(lt_movements).
*
*      "One serial assignment represents one piece
*      LOOP AT lt_movements INTO DATA(ls_movement).
*
*        IF ls_movement-SerialNumber IS INITIAL.
*          lv_error = 'An issued serial assignment has no serial number'.
*          EXIT.
*        ENDIF.
*
*        READ TABLE lt_balances
*          ASSIGNING FIELD-SYMBOL(<balance>)
*          WITH TABLE KEY
*            material  = ls_movement-Material
*            serial_no = ls_movement-SerialNumber.
*
*        IF sy-subrc <> 0.
*
*          INSERT VALUE #(
*            material  = ls_movement-Material
*            serial_no = ls_movement-SerialNumber
*            balance   = 0
*          ) INTO TABLE lt_balances.
*
*          READ TABLE lt_balances
*            ASSIGNING <balance>
*            WITH TABLE KEY
*              material  = ls_movement-Material
*              serial_no = ls_movement-SerialNumber.
*
*        ENDIF.
*
*        CASE ls_movement-GoodsMovementType.
*          WHEN '261'.
*            <balance>-balance = <balance>-balance + 1.
*          WHEN '262'.
*            <balance>-balance = <balance>-balance - 1.
*        ENDCASE.
*
*      ENDLOOP.
*
*      IF lv_error IS INITIAL.
*
*        LOOP AT lt_balances INTO DATA(ls_balance).
*
*          IF ls_balance-balance < 0
*             OR ls_balance-balance > 1.
*
*            lv_error =
*              |Check 261/262 history for serial { ls_balance-serial_no }|.
*
*            EXIT.
*
*          ENDIF.
*
*        ENDLOOP.
*
*        DELETE lt_balances WHERE balance = 0.
*
*        IF lv_error IS INITIAL AND lt_balances IS INITIAL.
*          lv_error = 'No eligible serials found. Check 261/262 postings'.
*        ENDIF.
*
*      ENDIF.
*
*    ENDIF.
*
*    "5. Check serial uniqueness against the item key
*    IF lv_error IS INITIAL.
*
*      LOOP AT lt_balances INTO ls_balance.
*
*        INSERT ls_balance-serial_no INTO TABLE lt_serial_keys.
*
*        IF sy-subrc <> 0.
*
*          lv_error =
*            |Serial { ls_balance-serial_no } occurs for multiple materials|.
*
*          EXIT.
*
*        ENDIF.
*
*      ENDLOOP.
*
*    ENDIF.
*
*    "6. Read and check existing draft items
*    IF lv_error IS INITIAL.
*
*      READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*        ENTITY Header BY \_Items
*        ALL FIELDS
*        WITH VALUE #( ( %tky = ls_header-%tky ) )
*        RESULT DATA(lt_existing)
*        FAILED DATA(ls_existing_failed)
*        REPORTED DATA(ls_existing_reported).
*
*      APPEND LINES OF ls_existing_reported-header
*        TO reported-header.
*
*      APPEND LINES OF ls_existing_reported-item
*        TO reported-item.
*
*      IF ls_existing_failed IS NOT INITIAL.
*
*        lv_error = 'Existing draft serials could not be read'.
*
*      ELSE.
*
*        LOOP AT lt_existing INTO DATA(ls_existing).
*
*          lv_existing_order = ls_existing-ProdOrder.
*          lv_existing_order =
*            |{ lv_existing_order ALPHA = IN WIDTH = 12 }|.
*
*          IF lv_existing_order <> lv_order.
*
*            lv_error =
*              'Order changed: discard this draft and create a new one'.
*
*            EXIT.
*
*          ENDIF.
*
*          IF NOT line_exists(
*            lt_balances[
*              material  = ls_existing-Material
*              serial_no = ls_existing-SerialNo
*            ]
*          ).
*
*            lv_error =
*              'Serial postings changed: discard this draft and fetch again'.
*
*            EXIT.
*
*          ENDIF.
*
*          IF ls_existing-Reject = abap_true.
*            lv_rejected_count = lv_rejected_count + 1.
*          ENDIF.
*
*        ENDLOOP.
*
*      ENDIF.
*
*    ENDIF.
*
*    "7. Report errors before changing any draft rows
*    IF lv_error IS NOT INITIAL.
*
*      APPEND VALUE #(
*        %tky = ls_header-%tky
*      ) TO failed-header.
*
*      APPEND VALUE #(
*        %tky = ls_header-%tky
*        %msg = new_message_with_text(
*          severity = if_abap_behv_message=>severity-error
*          text     = lv_error
*        )
*      ) TO reported-header.
*
*      CONTINUE.
*
*    ENDIF.
*
*    "8. Populate OrderType on existing draft serial rows
*    IF lt_existing IS NOT INITIAL.
*
*      MODIFY ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*        ENTITY Item
*        UPDATE FIELDS ( OrderType DisplaySerialNo )
*       WITH VALUE #(
*  FOR ls_existing_item IN lt_existing
*  (
*    %tky           = ls_existing_item-%tky
*    OrderType      = ls_header-OrderType
*    DisplaySerialNo =
*      |{ ls_existing_item-SerialNo ALPHA = OUT }|
*  )
*)
*        FAILED DATA(ls_type_failed)
*        REPORTED DATA(ls_type_reported).
*
*      APPEND LINES OF ls_type_failed-header
*        TO failed-header.
*
*      APPEND LINES OF ls_type_failed-item
*        TO failed-item.
*
*      APPEND LINES OF ls_type_reported-header
*        TO reported-header.
*
*      APPEND LINES OF ls_type_reported-item
*        TO reported-item.
*
*      IF ls_type_failed IS NOT INITIAL.
*
*        IF ls_type_failed-header IS INITIAL.
*          APPEND VALUE #(
*            %tky = ls_header-%tky
*          ) TO failed-header.
*        ENDIF.
*
*        CONTINUE.
*
*      ENDIF.
*
*    ENDIF.
*
*    "9. Build missing serial rows only
*    APPEND INITIAL LINE TO lt_create
*      ASSIGNING FIELD-SYMBOL(<create>).
*
*    <create>-%tky = ls_header-%tky.
*
*    LOOP AT lt_balances INTO ls_balance.
*
*      "Preserve existing rejection values and remarks
*      IF line_exists(
*        lt_existing[ SerialNo = ls_balance-serial_no ]
*      ).
*        CONTINUE.
*      ENDIF.
*
*      lv_index = lv_index + 1.
*
*      APPEND VALUE #(
*        %cid      = |SERIAL_{ lv_index }|
*        %is_draft = ls_header-%is_draft
*        SerialNo  = ls_balance-serial_no
*         DisplaySerialNo =
*    |{ ls_balance-serial_no ALPHA = OUT }|
*        ProdOrder = lv_order
*        OrderType = ls_header-OrderType
*        Stage     = ls_header-Stage
*        Material  = ls_balance-material
*        Reject    = abap_false
*      ) TO <create>-%target.
*
*    ENDLOOP.
*
*    "No new serial rows: leave the create request empty
*    IF <create>-%target IS INITIAL.
*      CLEAR lt_create.
*    ENDIF.
*
*    "10. Update count and create draft serial rows
*    MODIFY ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*
*      ENTITY Header
*      UPDATE FIELDS ( RejectedCount )
*      WITH VALUE #(
*        (
*          %tky          = ls_header-%tky
*          RejectedCount = lv_rejected_count
*        )
*      )
*
*      ENTITY Header
*      CREATE BY \_Items
*      FIELDS (
*        SerialNo
*        DisplaySerialNo
*        ProdOrder
*        OrderType
*        Stage
*        Material
*        Reject
*      )
*      WITH lt_create
*
*      MAPPED DATA(ls_mapped)
*      FAILED DATA(ls_modify_failed)
*      REPORTED DATA(ls_modify_reported).
*
*    APPEND LINES OF ls_modify_failed-header
*      TO failed-header.
*
*    APPEND LINES OF ls_modify_failed-item
*      TO failed-item.
*
*    APPEND LINES OF ls_modify_reported-header
*      TO reported-header.
*
*    APPEND LINES OF ls_modify_reported-item
*      TO reported-item.
*
*    IF ls_modify_failed IS NOT INITIAL.
*
*      IF ls_modify_failed-header IS INITIAL.
*        APPEND VALUE #(
*          %tky = ls_header-%tky
*        ) TO failed-header.
*      ENDIF.
*
*      APPEND VALUE #(
*        %tky = ls_header-%tky
*        %msg = new_message_with_text(
*          severity = if_abap_behv_message=>severity-error
*          text = 'Serial fetch could not update all draft rows'
*        )
*      ) TO reported-header.
*
*      CONTINUE.
*
*    ENDIF.
*
*    "11. Return the refreshed header
*    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*      ENTITY Header
*      ALL FIELDS
*      WITH VALUE #( ( %tky = ls_header-%tky ) )
*      RESULT DATA(lt_updated)
*      FAILED DATA(ls_return_failed)
*      REPORTED DATA(ls_return_reported).
*
*    APPEND LINES OF ls_return_failed-header
*      TO failed-header.
*
*    APPEND LINES OF ls_return_reported-header
*      TO reported-header.
*
*    LOOP AT lt_updated INTO DATA(ls_updated).
*
*      APPEND VALUE #(
*        %tky   = ls_updated-%tky
*        %param = ls_updated
*      ) TO result.
*
*    ENDLOOP.
*
*  ENDLOOP.
*
*ENDMETHOD.
*
*METHOD ValidateSerials.
*
*  READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*    ENTITY Header
*    FIELDS ( LoadingRejQty )
*    WITH CORRESPONDING #( keys )
*    RESULT DATA(lt_headers)
*    FAILED DATA(ls_read_failed)
*    REPORTED DATA(ls_read_reported).
*
*  LOOP AT ls_read_failed-header INTO DATA(ls_failed_header).
*    APPEND VALUE #(
*      %tky = ls_failed_header-%tky
*    ) TO failed-header.
*  ENDLOOP.
*
*  LOOP AT ls_read_reported-header INTO DATA(ls_read_header_msg).
*    APPEND VALUE #(
*      %tky = ls_read_header_msg-%tky
*      %msg = ls_read_header_msg-%msg
*    ) TO reported-header.
*  ENDLOOP.
*
*  LOOP AT ls_read_reported-item INTO DATA(ls_read_item_msg).
*    APPEND VALUE #(
*      %tky = ls_read_item_msg-%tky
*      %msg = ls_read_item_msg-%msg
*    ) TO reported-item.
*  ENDLOOP.
*
*  LOOP AT lt_headers INTO DATA(ls_header).
*
*    "Clear previous header validation messages
*    APPEND VALUE #(
*      %tky        = ls_header-%tky
*      %state_area = 'VALIDATE_SERIALS'
*    ) TO reported-header.
*
*    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*      ENTITY Header BY \_Items
*      FIELDS ( SerialNo Reject ReasonText )
*      WITH VALUE #( ( %tky = ls_header-%tky ) )
*      RESULT DATA(lt_items)
*      FAILED DATA(ls_items_failed)
*      REPORTED DATA(ls_items_reported).
*
*    LOOP AT ls_items_reported-header
*      INTO DATA(ls_items_header_msg).
*
*      APPEND VALUE #(
*        %tky = ls_items_header_msg-%tky
*        %msg = ls_items_header_msg-%msg
*      ) TO reported-header.
*
*    ENDLOOP.
*
*    LOOP AT ls_items_reported-item
*      INTO DATA(ls_items_item_msg).
*
*      APPEND VALUE #(
*        %tky             = ls_items_item_msg-%tky
*        %msg             = ls_items_item_msg-%msg
*        %path-Header-%tky = ls_header-%tky
*      ) TO reported-item.
*
*    ENDLOOP.
*
*    IF ls_items_failed IS NOT INITIAL.
*
*      APPEND VALUE #(
*        %tky = ls_header-%tky
*      ) TO failed-header.
*
*      APPEND VALUE #(
*        %tky        = ls_header-%tky
*        %state_area = 'VALIDATE_SERIALS'
*        %msg = new_message_with_text(
*          severity = if_abap_behv_message=>severity-error
*          text = 'Serial numbers could not be checked. Fetch again before saving'
*        )
*      ) TO reported-header.
*
*      CONTINUE.
*
*    ENDIF.
*
*    DATA(lv_rejected_count) = 0.
*    DATA(lv_missing_reason) = abap_false.
*
*    LOOP AT lt_items INTO DATA(ls_item).
*
*      "Reuse the existing state area to clear old code/reason errors
*      APPEND VALUE #(
*        %tky             = ls_item-%tky
*        %state_area      = 'VALIDATE_REJECTION_CODE'
*        %path-Header-%tky = ls_header-%tky
*      ) TO reported-item.
*
*      IF ls_item-Reject <> abap_true.
*        CONTINUE.
*      ENDIF.
*
*      lv_rejected_count = lv_rejected_count + 1.
*
*      "Only rejection reason is required
*      IF ls_item-ReasonText IS INITIAL.
*
*        lv_missing_reason = abap_true.
*
*        APPEND VALUE #(
*          %tky = ls_item-%tky
*        ) TO failed-item.
*
*        APPEND VALUE #(
*          %tky                = ls_item-%tky
*          %state_area         = 'VALIDATE_REJECTION_CODE'
*          %element-ReasonText = if_abap_behv=>mk-on
*          %path-Header-%tky    = ls_header-%tky
*          %msg = new_message_with_text(
*            severity = if_abap_behv_message=>severity-error
*            text = |Select a rejection reason for serial { ls_item-SerialNo }|
*          )
*        ) TO reported-item.
*
*      ENDIF.
*
*    ENDLOOP.
*
*    "Positive rejection quantity requires serial rows
*    IF ls_header-LoadingRejQty > 0
*       AND lt_items IS INITIAL.
*
*      APPEND VALUE #(
*        %tky = ls_header-%tky
*      ) TO failed-header.
*
*      APPEND VALUE #(
*        %tky                   = ls_header-%tky
*        %state_area            = 'VALIDATE_SERIALS'
*        %element-LoadingRejQty = if_abap_behv=>mk-on
*        %msg = new_message_with_text(
*          severity = if_abap_behv_message=>severity-error
*          text = 'Fetch serial numbers before saving'
*        )
*      ) TO reported-header.
*
*      CONTINUE.
*
*    ENDIF.
*
*    "Quantity must match the actual rejected serial count
*    IF ls_header-LoadingRejQty <> lv_rejected_count.
*
*      APPEND VALUE #(
*        %tky = ls_header-%tky
*      ) TO failed-header.
*
*      APPEND VALUE #(
*        %tky                   = ls_header-%tky
*        %state_area            = 'VALIDATE_SERIALS'
*        %element-LoadingRejQty = if_abap_behv=>mk-on
*        %element-RejectedCount = if_abap_behv=>mk-on
*        %msg = new_message_with_text(
*          severity = if_abap_behv_message=>severity-error
*          text = |Loading rejection quantity is { ls_header-LoadingRejQty }, but { lv_rejected_count } serials are marked Reject. Both must match|
*        )
*      ) TO reported-header.
*
*    ELSEIF lv_missing_reason = abap_true.
*
*      APPEND VALUE #(
*        %tky = ls_header-%tky
*      ) TO failed-header.
*
*    ENDIF.
*
*  ENDLOOP.
*
*ENDMETHOD.
*
*ENDCLASS.
*
*CLASS lhc_item DEFINITION
*  INHERITING FROM cl_abap_behavior_handler.
*
*  PRIVATE SECTION.
*
*    METHODS RejectAllItems FOR MODIFY
*      IMPORTING keys FOR ACTION Item~RejectAllItems
*      RESULT result.
*
*    METHODS UnrejectAllItems FOR MODIFY
*      IMPORTING keys FOR ACTION Item~UnrejectAllItems
*      RESULT result.
*
*      METHODS SetRejectionRemarks FOR DETERMINE ON MODIFY
*  IMPORTING keys FOR Item~SetRejectionRemarks.
*
*      METHODS get_instance_features
*  FOR INSTANCE FEATURES
*  keys REQUEST requested_features
*  FOR Item RESULT result.
*
*ENDCLASS.
*
*
*CLASS lhc_item IMPLEMENTATION.
*
*  METHOD RejectAllItems.
*
*    "Find parent headers of the selected serial rows
*    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*      ENTITY Item BY \_Header
*      ALL FIELDS
*      WITH CORRESPONDING #( keys )
*      RESULT DATA(lt_headers)
*      FAILED DATA(ls_header_failed)
*      REPORTED DATA(ls_header_reported).
*
*    failed   = CORRESPONDING #( ls_header_failed ).
*    reported = CORRESPONDING #( ls_header_reported ).
*
*    IF lt_headers IS INITIAL.
*      RETURN.
*    ENDIF.
*
*    "Read all serial rows belonging to those headers
*    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*      ENTITY Header BY \_Items
*      ALL FIELDS
*      WITH CORRESPONDING #( lt_headers )
*      RESULT DATA(lt_items)
*      FAILED DATA(ls_items_failed)
*      REPORTED DATA(ls_items_reported).
*
*    APPEND LINES OF ls_items_failed-header
*      TO failed-header.
*    APPEND LINES OF ls_items_failed-item
*      TO failed-item.
*
*    APPEND LINES OF ls_items_reported-header
*      TO reported-header.
*    APPEND LINES OF ls_items_reported-item
*      TO reported-item.
*
*    IF ls_items_failed IS NOT INITIAL.
*      RETURN.
*    ENDIF.
*
*    "Reject all serials; preserve existing codes and remarks
*    MODIFY ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*      ENTITY Item
*      UPDATE FIELDS ( Reject )
*      WITH VALUE #(
*        FOR ls_item IN lt_items
*        (
*          %tky   = ls_item-%tky
*          Reject = abap_true
*        )
*      )
*      FAILED DATA(ls_update_failed)
*      REPORTED DATA(ls_update_reported).
*
*    APPEND LINES OF ls_update_failed-header
*      TO failed-header.
*    APPEND LINES OF ls_update_failed-item
*      TO failed-item.
*
*    APPEND LINES OF ls_update_reported-header
*      TO reported-header.
*    APPEND LINES OF ls_update_reported-item
*      TO reported-item.
*
*    IF ls_update_failed IS NOT INITIAL.
*      RETURN.
*    ENDIF.
*
*    "Re-read actual item values before calculating the count
*    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*      ENTITY Header BY \_Items
*      ALL FIELDS
*      WITH CORRESPONDING #( lt_headers )
*      RESULT DATA(lt_after)
*      FAILED DATA(ls_after_failed)
*      REPORTED DATA(ls_after_reported).
*
*    APPEND LINES OF ls_after_failed-header
*      TO failed-header.
*    APPEND LINES OF ls_after_failed-item
*      TO failed-item.
*
*    APPEND LINES OF ls_after_reported-header
*      TO reported-header.
*    APPEND LINES OF ls_after_reported-item
*      TO reported-item.
*
*    IF ls_after_failed IS NOT INITIAL.
*      RETURN.
*    ENDIF.
*
*    DATA lt_header_updates TYPE TABLE FOR UPDATE
*      ZI_LOAD_REJ_HDR.
*
*    LOOP AT lt_headers INTO DATA(ls_header).
*
*      DATA(lv_count) = 0.
*
*      LOOP AT lt_after INTO DATA(ls_after)
*        WHERE HeaderUUID = ls_header-HeaderUUID
*          AND %is_draft = ls_header-%is_draft
*          AND Reject = abap_true.
*
*        lv_count = lv_count + 1.
*
*      ENDLOOP.
*
*      APPEND VALUE #(
*        %tky          = ls_header-%tky
*        RejectedCount = lv_count
*      ) TO lt_header_updates.
*
*    ENDLOOP.
*
*    MODIFY ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*      ENTITY Header
*      UPDATE FIELDS ( RejectedCount )
*      WITH lt_header_updates
*      FAILED DATA(ls_count_failed)
*      REPORTED DATA(ls_count_reported).
*
*    APPEND LINES OF ls_count_failed-header
*      TO failed-header.
*    APPEND LINES OF ls_count_failed-item
*      TO failed-item.
*
*    APPEND LINES OF ls_count_reported-header
*      TO reported-header.
*    APPEND LINES OF ls_count_reported-item
*      TO reported-item.
*
*    IF ls_count_failed IS NOT INITIAL.
*      RETURN.
*    ENDIF.
*
*    "Return the originally selected serial rows
*    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*      ENTITY Item
*      ALL FIELDS
*      WITH CORRESPONDING #( keys )
*      RESULT DATA(lt_result)
*      FAILED DATA(ls_result_failed)
*      REPORTED DATA(ls_result_reported).
*
*    APPEND LINES OF ls_result_failed-item
*      TO failed-item.
*    APPEND LINES OF ls_result_reported-item
*      TO reported-item.
*
*    result = VALUE #(
*      FOR ls_result IN lt_result
*      (
*        %tky   = ls_result-%tky
*        %param = ls_result
*      )
*    ).
*
*  ENDMETHOD.
*
*
*  METHOD UnrejectAllItems.
*
*    "Find parent headers of the selected serial rows
*    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*      ENTITY Item BY \_Header
*      ALL FIELDS
*      WITH CORRESPONDING #( keys )
*      RESULT DATA(lt_headers)
*      FAILED DATA(ls_header_failed)
*      REPORTED DATA(ls_header_reported).
*
*    failed   = CORRESPONDING #( ls_header_failed ).
*    reported = CORRESPONDING #( ls_header_reported ).
*
*    IF lt_headers IS INITIAL.
*      RETURN.
*    ENDIF.
*
*    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*      ENTITY Header BY \_Items
*      ALL FIELDS
*      WITH CORRESPONDING #( lt_headers )
*      RESULT DATA(lt_items)
*      FAILED DATA(ls_items_failed)
*      REPORTED DATA(ls_items_reported).
*
*    APPEND LINES OF ls_items_failed-header
*      TO failed-header.
*    APPEND LINES OF ls_items_failed-item
*      TO failed-item.
*
*    APPEND LINES OF ls_items_reported-header
*      TO reported-header.
*    APPEND LINES OF ls_items_reported-item
*      TO reported-item.
*
*    IF ls_items_failed IS NOT INITIAL.
*      RETURN.
*    ENDIF.
*
*    "Unreject all and clear rejection-specific values
*    MODIFY ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*      ENTITY Item
*      UPDATE FIELDS (
*        Reject
*        RejCode
*        ReasonText
*        Remarks
*      )
*      WITH VALUE #(
*        FOR ls_item IN lt_items
*        (
*          %tky       = ls_item-%tky
*          Reject     = abap_false
*          RejCode    = ''
*          ReasonText = ''
*          Remarks    = ''
*        )
*      )
*      FAILED DATA(ls_update_failed)
*      REPORTED DATA(ls_update_reported).
*
*    APPEND LINES OF ls_update_failed-header
*      TO failed-header.
*    APPEND LINES OF ls_update_failed-item
*      TO failed-item.
*
*    APPEND LINES OF ls_update_reported-header
*      TO reported-header.
*    APPEND LINES OF ls_update_reported-item
*      TO reported-item.
*
*    IF ls_update_failed IS NOT INITIAL.
*      RETURN.
*    ENDIF.
*
*    MODIFY ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*      ENTITY Header
*      UPDATE FIELDS ( RejectedCount )
*      WITH VALUE #(
*        FOR ls_header IN lt_headers
*        (
*          %tky          = ls_header-%tky
*          RejectedCount = 0
*        )
*      )
*      FAILED DATA(ls_count_failed)
*      REPORTED DATA(ls_count_reported).
*
*    APPEND LINES OF ls_count_failed-header
*      TO failed-header.
*    APPEND LINES OF ls_count_failed-item
*      TO failed-item.
*
*    APPEND LINES OF ls_count_reported-header
*      TO reported-header.
*    APPEND LINES OF ls_count_reported-item
*      TO reported-item.
*
*    IF ls_count_failed IS NOT INITIAL.
*      RETURN.
*    ENDIF.
*
*    READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*      ENTITY Item
*      ALL FIELDS
*      WITH CORRESPONDING #( keys )
*      RESULT DATA(lt_result)
*      FAILED DATA(ls_result_failed)
*      REPORTED DATA(ls_result_reported).
*
*    APPEND LINES OF ls_result_failed-item
*      TO failed-item.
*    APPEND LINES OF ls_result_reported-item
*      TO reported-item.
*
*    result = VALUE #(
*      FOR ls_result IN lt_result
*      (
*        %tky   = ls_result-%tky
*        %param = ls_result
*      )
*    ).
*
*  ENDMETHOD.
*
*  METHOD SetRejectionRemarks.
*
*  READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*    ENTITY Item
*    FIELDS ( Reject Remarks )
*    WITH CORRESPONDING #( keys )
*    RESULT DATA(lt_items)
*    FAILED DATA(ls_read_failed)
*    REPORTED DATA(ls_read_reported).
*
*  "Copy messages individually to avoid structure conversion errors
*  LOOP AT ls_read_reported-header INTO DATA(ls_read_header_message).
*
*    APPEND VALUE #(
*      %tky = ls_read_header_message-%tky
*      %msg = ls_read_header_message-%msg
*    ) TO reported-header.
*
*  ENDLOOP.
*
*  LOOP AT ls_read_reported-item INTO DATA(ls_read_item_message).
*
*    APPEND VALUE #(
*      %tky = ls_read_item_message-%tky
*      %msg = ls_read_item_message-%msg
*    ) TO reported-item.
*
*  ENDLOOP.
*
*  IF ls_read_failed IS NOT INITIAL.
*    RETURN.
*  ENDIF.
*
*  DATA lt_updates TYPE TABLE FOR UPDATE ZI_LOAD_REJ_ITM.
*
*  LOOP AT lt_items INTO DATA(ls_item).
*
*    IF ls_item-Reject = abap_true.
*
*      "Set the default only when remarks are blank
*      IF ls_item-Remarks IS INITIAL.
*
*        APPEND VALUE #(
*          %tky    = ls_item-%tky
*          Remarks = 'Loading Rejection'
*        ) TO lt_updates.
*
*      ENDIF.
*
*    ELSE.
*
*      "Clear the automatic default when Reject is unticked
*      "Preserve any different remarks entered by the user
*      IF ls_item-Remarks = 'Loading Rejection'.
*
*        APPEND VALUE #(
*          %tky    = ls_item-%tky
*          Remarks = ''
*        ) TO lt_updates.
*
*      ENDIF.
*
*    ENDIF.
*
*  ENDLOOP.
*
*  IF lt_updates IS INITIAL.
*    RETURN.
*  ENDIF.
*
*  MODIFY ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*    ENTITY Item
*    UPDATE FIELDS ( Remarks )
*    WITH lt_updates
*    FAILED DATA(ls_update_failed)
*    REPORTED DATA(ls_update_reported).
*
*  LOOP AT ls_update_reported-header INTO DATA(ls_header_message).
*
*    APPEND VALUE #(
*      %tky = ls_header_message-%tky
*      %msg = ls_header_message-%msg
*    ) TO reported-header.
*
*  ENDLOOP.
*
*  LOOP AT ls_update_reported-item INTO DATA(ls_item_message).
*
*    APPEND VALUE #(
*      %tky = ls_item_message-%tky
*      %msg = ls_item_message-%msg
*    ) TO reported-item.
*
*  ENDLOOP.
*
*  LOOP AT ls_update_failed-item INTO DATA(ls_failed_item).
*
*    APPEND VALUE #(
*      %tky = ls_failed_item-%tky
*      %msg = new_message_with_text(
*        severity = if_abap_behv_message=>severity-error
*        text = 'Could not update loading rejection remarks'
*      )
*    ) TO reported-item.
*
*  ENDLOOP.
*
*ENDMETHOD.
*
*  METHOD get_instance_features.
*
*  READ ENTITIES OF ZI_LOAD_REJ_HDR IN LOCAL MODE
*    ENTITY Item
*    FIELDS ( Reject )
*    WITH CORRESPONDING #( keys )
*    RESULT DATA(lt_items)
*    FAILED DATA(ls_read_failed)
*    REPORTED DATA(ls_read_reported).
*
*  failed   = CORRESPONDING #( ls_read_failed ).
*  reported = CORRESPONDING #( ls_read_reported ).
*
*  result = VALUE #(
*    FOR ls_item IN lt_items
*    (
*      %tky = ls_item-%tky
*
*      %field-ReasonText = COND #(
*        WHEN ls_item-Reject = abap_true
*          THEN if_abap_behv=>fc-f-unrestricted
*        ELSE
*          if_abap_behv=>fc-f-read_only
*      )
*    )
*  ).
*
*ENDMETHOD.
*
*ENDCLASS.

