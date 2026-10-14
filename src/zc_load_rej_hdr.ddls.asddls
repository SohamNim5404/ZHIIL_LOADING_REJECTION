@AccessControl.authorizationCheck: #NOT_REQUIRED
@EndUserText.label: 'Loading Rejection Header Consumption'
@Metadata.allowExtensions: true

define root view entity ZC_LOAD_REJ_HDR
  as projection on ZI_LOAD_REJ_HDR
{
key  HeaderUUID,
    ProdOrder,
      Plant,
      OrderType,
      Stage,
      WorkCenter,
      BATCHNUMBER,
      Material,
      QuantityUnit,
      displayunit,
      LoadedQty,
      LoadingRejQty,
      RejectedCount,
      Active,
      CreatedBy,
      CreatedAt,
      LocalLastChangedAt,
      LastChangedAt,

      _Items : redirected to composition child ZC_LOAD_REJ_ITM
}
