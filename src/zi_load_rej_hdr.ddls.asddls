@AccessControl.authorizationCheck: #NOT_REQUIRED
@EndUserText.label: 'Loading Rejection Order Header'
@Metadata.ignorePropagatedAnnotations: true

define root view entity ZI_LOAD_REJ_HDR
  as select from zload_rej_hd

  composition [0..*] of ZI_LOAD_REJ_ITM as _Items

{
 key header_uuid as HeaderUUID,
    prod_order  as ProdOrder,

      plant                 as Plant,
      order_type            as OrderType,
      stage                 as Stage,
      @Consumption.valueHelpDefinition: [{
        entity: {
          name: 'ZWORK_CEN_VH',
          element: 'work_center'
        }
      }]
      work_center           as WorkCenter,
      batch_number          as BATCHNUMBER,
     material as Material,
      quantity_unit as QuantityUnit,
      displayunit   as displayunit,

cast( loaded_qty as abap.dec(13,3) ) as LoadedQty,

cast( loading_rej_qty as abap.dec(13,3) ) as LoadingRejQty,

      rejected_count as RejectedCount,
      active                as Active,

      @Semantics.user.createdBy: true
      created_by            as CreatedBy,

      @Semantics.systemDateTime.createdAt: true
      created_at            as CreatedAt,

      @Semantics.systemDateTime.localInstanceLastChangedAt: true
      local_last_changed_at as LocalLastChangedAt,

      @Semantics.systemDateTime.lastChangedAt: true
      last_changed_at       as LastChangedAt,

      _Items
}
