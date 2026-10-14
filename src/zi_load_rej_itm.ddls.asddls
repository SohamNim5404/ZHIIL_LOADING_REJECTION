@AccessControl.authorizationCheck: #NOT_REQUIRED
@EndUserText.label: 'Loading Rejection Item'
@Metadata.ignorePropagatedAnnotations: true

define view entity ZI_LOAD_REJ_ITM
  as select from zload_rej_item

  association to parent ZI_LOAD_REJ_HDR as _Header
    on $projection.HeaderUUID = _Header.HeaderUUID

{
  key header_uuid as HeaderUUID,
  key serial_no   as SerialNo,
      displayserial_no as displayserialno,
      prod_order  as ProdOrder,
      order_type  as OrderType,
      stage       as Stage,
      material    as Material,
      rej_code    as RejCode,
      reject      as Reject,

   @Consumption.valueHelpDefinition: [
  {
    entity: {
      name: 'ZREJECT_TEXT_VH',
      element: 'RejectionText'
    },
    additionalBinding: [
      {
        localElement: 'OrderType',
        element: 'Order_Type',
        usage: #FILTER
      },
      {
        localElement: 'RejCode',
        element: 'RejectionCode',
        usage: #RESULT
      }
    ]
  }
]
      rejectiontext as ReasonText,

      remarks as Remarks,

      @Semantics.user.createdBy: true
      created_by as CreatedBy,

      @Semantics.systemDateTime.createdAt: true
      created_at as CreatedAt,

      @Semantics.systemDateTime.localInstanceLastChangedAt: true
      local_last_changed_at as LocalLastChangedAt,

      @Semantics.systemDateTime.lastChangedAt: true
      last_changed_at as LastChangedAt,

      _Header
}
