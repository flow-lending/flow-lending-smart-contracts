use aiken/crypto.{Blake2b_224, Hash, VerificationKey}
use cardano/assets.{AssetName, PolicyId}
use cardano/transaction.{OutputReference}

pub type PubKeyHash =
  Hash<Blake2b_224, VerificationKey>

pub type Asset {
  policy_id: PolicyId,
  asset_name: AssetName,
}

pub type CollateralInfo {
  collateral_asset: Asset,
  collateral_decimals: Int,
  oracle_nft: Asset,
  liquidation_threshold: Int,
  max_borrow_ltv: Int,
}

pub type PoolInfoDatum {
  pool_id: OutputReference,
  envelope_amount: Int,
  pool_asset: Asset,
  pool_asset_decimals: Int,
  ctoken: Asset,
  vault_authtoken: Asset,
  batcher_policy_id: ByteArray,
  order_script_hash: ByteArray,
  vault_script_hash: ByteArray,
  pool_stake_key: Option<PubKeyHash>,
  reserve_factor_percentage: Int,
  collateral_infos: List<CollateralInfo>,
  kink: Int,
  base_rate: Int,
  slope_low: Int,
  slope_high: Int,
}

pub type PoolParams {
  admin_pkh: ByteArray,
  pool_nft: Asset,
  pool_info_nft: Asset,
}

pub type PoolDatum {
  pool_id: OutputReference,
  total_supplied: Int,
  total_borrowed: Int,
  reserve: Int,
  total_ctoken: Int,
}

pub type OrderDatum {
  ODeposit {
    o_pool_id: OutputReference,
    o_owner_pkh: PubKeyHash,
    o_owner_stake_key: Option<PubKeyHash>,
    o_batcher_fee: Int,
    o_amount: Int,
  }
  OWithdraw {
    o_pool_id: OutputReference,
    o_owner_pkh: PubKeyHash,
    o_owner_stake_key: Option<PubKeyHash>,
    o_batcher_fee: Int,
    o_amount: Int,
  }
  OBorrow {
    o_pool_id: OutputReference,
    o_owner_pkh: PubKeyHash,
    o_owner_stake_key: Option<PubKeyHash>,
    o_batcher_fee: Int,
    o_principal: Int,
    o_collateral_amount: Int,
    o_collateral_asset: Asset,
  }
  ORepay {
    o_pool_id: OutputReference,
    o_batcher_fee: Int,
    o_borrow_id: OutputReference,
    o_owner_pkh: PubKeyHash,
    o_time: Int,
  }
  OLiquidate {
    o_pool_id: OutputReference,
    o_batcher_fee: Int,
    o_owner_pkh: PubKeyHash,
    o_borrow_id: OutputReference,
  }
}

pub type VaultDatum {
  pool_id: OutputReference,
  borrow_id: OutputReference,
  owner_pkh: PubKeyHash,
  owner_stake_key: Option<PubKeyHash>,
  collateral_amount: Int,
  collateral_asset: Asset,
  collateral_decimals: Int,
  interest_rate: Int,
  start_time: Int,
  principal: Int,
}

pub type VaultRedeemer {
  VRepay
  VLiquidate
}

pub type OracleDatum {
  price: Int,
  updated_at: Int,
}
