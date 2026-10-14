@AccessControl.authorizationCheck: #NOT_REQUIRED
@EndUserText.label: 'Loading Rejection Item Consumption'
@Metadata.allowExtensions: true
@UI.createHidden: true

define view entity ZC_LOAD_REJ_ITM
  as projection on ZI_LOAD_REJ_ITM
{
  key  HeaderUUID,
key  SerialNo,
 displayserialno,
   ProdOrder,
      OrderType,
      Stage,
      Material,
      RejCode,
      Reject,
      ReasonText,
      Remarks,
      CreatedBy,
      CreatedAt,
      LocalLastChangedAt,
      LastChangedAt,

      _Header : redirected to parent ZC_LOAD_REJ_HDR
}
