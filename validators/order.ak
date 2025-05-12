use aiken/collection/list
use cardano/assets
use cardano/transaction.{InlineDatum, OutputReference, Transaction}
use types.{
  Asset, OBorrow, ODeposit, OLiquidate, ORepay, OWithdraw, OrderDatum, PoolDatum,
}

pub type OrderRedeemer {
  Apply { pool_in_idx: Int }
  Cancel { order_in_idx: Int }
}

pub type OrderParams {
  pool_id: OutputReference,
  pool_nft: Asset,
}

validator order(params: OrderParams) {
  spend(
    _datum: Option<Data>,
    redeemer: OrderRedeemer,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    let Transaction { inputs, extra_signatories, .. } = self
    when redeemer is {
      Apply { pool_in_idx } -> {
        expect Some(pool_input) = list.at(inputs, pool_in_idx)
        expect InlineDatum(pool_inline_datum) = pool_input.output.datum
        expect pool_datum: PoolDatum = pool_inline_datum
        expect pool_datum.pool_id == params.pool_id
        assets.quantity_of(
          pool_input.output.value,
          params.pool_nft.policy_id,
          params.pool_nft.asset_name,
        ) == 1
      }
      Cancel { order_in_idx } -> {
        expect Some(order_input) = list.at(inputs, order_in_idx)
        expect order_input.output_reference == own_ref
        expect InlineDatum(order_inline_datum) = order_input.output.datum
        expect order_datum: OrderDatum = order_inline_datum
        when order_datum is {
          ODeposit { o_pool_id, o_owner_pkh, .. } -> {
            expect o_pool_id == params.pool_id
            list.has(extra_signatories, o_owner_pkh)
          }
          OWithdraw { o_pool_id, o_owner_pkh, .. } -> {
            expect o_pool_id == params.pool_id
            list.has(extra_signatories, o_owner_pkh)
          }
          OBorrow { o_pool_id, o_owner_pkh, .. } -> {
            expect o_pool_id == params.pool_id
            list.has(extra_signatories, o_owner_pkh)
          }
          ORepay { o_pool_id, o_owner_pkh, .. } -> {
            expect o_pool_id == params.pool_id
            list.has(extra_signatories, o_owner_pkh)
          }
          OLiquidate { o_pool_id, o_owner_pkh, .. } -> {
            expect o_pool_id == params.pool_id
            list.has(extra_signatories, o_owner_pkh)
          }
        }
      }
    }
  }

  else(_) {
    fail
  }
}

test add_value() {
  let value =
    assets.zero
      |> assets.add(assets.ada_policy_id, assets.ada_asset_name, -1000)
  assets.match(assets.zero, value, >=)
}
