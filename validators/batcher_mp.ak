use aiken/collection/list
use cardano/address.{Credential}
use cardano/assets.{flatten}
use cardano/transaction.{OutputReference, Transaction}

pub type LicenseRedeemer {
  Mint { dead_line: ByteArray }
  Burn
}

pub type BatcherParams {
  admin_pkh: ByteArray,
  pool_id: OutputReference,
}

validator batcher(params: BatcherParams) {
  mint(redeemer: LicenseRedeemer, policy_id: ByteArray, self: Transaction) {
    let Transaction { extra_signatories, mint, .. } = self
    expect list.has(extra_signatories, params.admin_pkh)
    when redeemer is {
      Mint { dead_line } -> flatten(mint) == [(policy_id, dead_line, 1)]
      Burn ->
        list.foldl(
          flatten(mint),
          True,
          fn(curr, acc) {
            let (_, _, quantity) = curr
            acc && quantity < 0
          },
        )
    }
  }

  withdraw(_redeemer: Data, _account: Credential, self: Transaction) {
    let Transaction { extra_signatories, .. } = self
    list.has(extra_signatories, params.admin_pkh)
  }

  publish(_redeemer: Data, _account: Credential, self: Transaction) {
    let Transaction { extra_signatories, .. } = self
    list.has(extra_signatories, params.admin_pkh)
  }

  else(_) {
    fail
  }
}
