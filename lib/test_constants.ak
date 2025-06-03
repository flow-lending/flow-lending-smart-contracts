use aiken/primitive/string
use cardano/address.{from_script}
use cardano/assets
use cardano/transaction.{InlineDatum, Input, NoDatum, Output, OutputReference}
use constants.{pool_info_nft_tn, pool_nft_tn}
use types.{Asset, CollateralInfo, PoolDatum, PoolInfoDatum}

pub const t_admin_pkh =
  #"6648c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e"

pub const t_pool_authtoken_policy_id =
  #"2d6c58112bbb5bab2940b09a2350d7814b3077822f622e740e392181"

pub const license_symbol =
  #"6648c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e"

pub const t_pool_info_outref =
  OutputReference {
    transaction_id: #"2e49e6648c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c",
    output_index: 0,
  }

pub const t_pool_outref =
  OutputReference {
    transaction_id: #"7cffe3c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c",
    output_index: 0,
  }

pub const t_pool_id =
  OutputReference {
    transaction_id: #"8f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b6b7d77978",
    output_index: 1,
  }

pub const t_collateral_asset =
  Asset {
    policy_id: "9c4252d86702c8c7cffe3c8f2b6b7d779788f50f4c9f",
    asset_name: "2f4c2e49e664",
  }

pub const t_collateral_asset_ada =
  Asset { policy_id: assets.ada_policy_id, asset_name: assets.ada_asset_name }

pub const t_oracle_nft =
  Asset {
    policy_id: "8f2b6b7d779788f50f4c9f9c4252d86702c8c7cffe3c",
    asset_name: "49e6642f4c2e",
  }

pub const t_collateral_info =
  CollateralInfo {
    collateral_asset: t_collateral_asset,
    collateral_decimals: 1_000_000,
    oracle_nft: t_oracle_nft,
    liquidation_threshold: 7_500,
    max_borrow_ltv: 5_000,
  }

pub const t_collateral_info_ada =
  CollateralInfo {
    collateral_asset: t_collateral_asset_ada,
    collateral_decimals: 1_000_000,
    oracle_nft: t_oracle_nft,
    liquidation_threshold: 7_500,
    max_borrow_ltv: 5_000,
  }

pub const t_valut_authtoken =
  Asset {
    policy_id: #"8c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e664",
    asset_name: string.to_bytearray(@"fVault"),
  }

pub const t_pool_info_datum =
  PoolInfoDatum {
    pool_id: t_pool_id,
    envelope_amount: 2_000_000,
    pool_asset: Asset {
      policy_id: assets.ada_policy_id,
      asset_name: assets.ada_asset_name,
    },
    pool_asset_decimals: 1_000_000,
    ctoken: Asset {
      policy_id: #"8c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e664",
      asset_name: string.to_bytearray(@"fADA"),
    },
    vault_authtoken: t_valut_authtoken,
    batcher_policy_id: license_symbol,
    order_script_hash: #"8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c",
    vault_script_hash: #"702c2f4c2e49e6648c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86",
    pool_stake_key: Some(
      #"788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b6b7d779",
    ),
    // 10 %
    reserve_factor_percentage: 1_000,
    collateral_infos: [t_collateral_info],
    kink: 8000,
    base_rate: 200,
    slope_low: 1000,
    slope_high: 5000,
  }

pub const t_pool_info_datum_non_ada =
  PoolInfoDatum {
    pool_id: t_pool_id,
    envelope_amount: 2_000_000,
    pool_asset: Asset {
      policy_id: #"c4252d86702c2f4c2e49e6648c7cffe3c8f2b6b7d779788f50f4c9f9",
      asset_name: #"f4c2e49e664c4252d86702c2",
    },
    pool_asset_decimals: 1_000_000,
    ctoken: Asset {
      policy_id: #"8c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e664",
      asset_name: string.to_bytearray(@"fNonADA"),
    },
    vault_authtoken: t_valut_authtoken,
    batcher_policy_id: license_symbol,
    order_script_hash: #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
    vault_script_hash: #"702c2f4c2e49e6648c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86",
    pool_stake_key: Some(
      #"788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b6b7d779",
    ),
    // 10 %
    reserve_factor_percentage: 1_000,
    collateral_infos: [t_collateral_info],
    kink: 8000,
    base_rate: 200,
    slope_low: 1000,
    slope_high: 5000,
  }

pub const t_pool_info_datum_ada_collateral =
  PoolInfoDatum {
    pool_id: t_pool_id,
    envelope_amount: 2_000_000,
    pool_asset: Asset {
      policy_id: #"c4252d86702c2f4c2e49e6648c7cffe3c8f2b6b7d779788f50f4c9f9",
      asset_name: #"f4c2e49e664c4252d86702c2",
    },
    pool_asset_decimals: 1_000_000,
    ctoken: Asset {
      policy_id: #"8c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e664",
      asset_name: string.to_bytearray(@"fNonADA"),
    },
    vault_authtoken: t_valut_authtoken,
    batcher_policy_id: license_symbol,
    order_script_hash: #"8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c",
    vault_script_hash: #"702c2f4c2e49e6648c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86",
    pool_stake_key: Some(
      #"788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b6b7d779",
    ),
    // 10 %
    reserve_factor_percentage: 1_000,
    collateral_infos: [t_collateral_info_ada],
    kink: 8000,
    base_rate: 200,
    slope_low: 1000,
    slope_high: 5000,
  }

pub const t_init_pool_datum =
  PoolDatum {
    pool_id: t_pool_id,
    total_supplied: 0,
    total_borrowed: 0,
    reserve: 0,
    total_ctoken: 0,
  }

pub const t_pool_info_script_hash =
  #"9c4252d86702c2f4c2e49e6648c7cffe3c8f2b6b7d779788f50f4c9f"

pub const t_pool_script_hash =
  #"8c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e664"

pub const t_pool_info_nft =
  Asset { policy_id: t_pool_authtoken_policy_id, asset_name: pool_info_nft_tn }

pub const t_pool_nft =
  Asset { policy_id: t_pool_authtoken_policy_id, asset_name: pool_nft_tn }

pub const t_pool_info_output =
  Output {
    address: from_script(t_pool_info_script_hash)
      |> address.with_delegation_script(
          #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
        ),
    value: assets.from_lovelace(2_000_000)
      |> assets.add(t_pool_authtoken_policy_id, pool_info_nft_tn, 1),
    datum: InlineDatum(t_pool_info_datum),
    reference_script: None,
  }

pub const t_pool_info_output_non_ada =
  Output {
    address: from_script(t_pool_info_script_hash)
      |> address.with_delegation_script(
          #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
        ),
    value: assets.from_lovelace(2_000_000)
      |> assets.add(t_pool_authtoken_policy_id, pool_info_nft_tn, 1),
    datum: InlineDatum(t_pool_info_datum_non_ada),
    reference_script: None,
  }

pub const t_pool_info_output_ada_collateral =
  Output {
    address: from_script(t_pool_info_script_hash)
      |> address.with_delegation_script(
          #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
        ),
    value: assets.from_lovelace(2_000_000)
      |> assets.add(t_pool_authtoken_policy_id, pool_info_nft_tn, 1),
    datum: InlineDatum(t_pool_info_datum_ada_collateral),
    reference_script: None,
  }

pub const t_init_pool_output =
  Output {
    address: from_script(t_pool_script_hash)
      |> address.with_delegation_script(
          #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
        ),
    value: assets.from_lovelace(2_000_000)
      |> assets.add(t_pool_authtoken_policy_id, pool_nft_tn, 1),
    datum: InlineDatum(t_init_pool_datum),
    reference_script: None,
  }

pub fn test_get_pool_info() -> (Input, PoolInfoDatum) {
  let t_pool_info_input =
    Input { output_reference: t_pool_info_outref, output: t_pool_info_output }
  (t_pool_info_input, t_pool_info_datum)
}

pub fn test_get_pool_info_non_ada() -> (Input, PoolInfoDatum) {
  let t_pool_info_input =
    Input {
      output_reference: t_pool_info_outref,
      output: t_pool_info_output_non_ada,
    }
  (t_pool_info_input, t_pool_info_datum_non_ada)
}

pub fn test_get_pool_info_ada_collateral() -> (Input, PoolInfoDatum) {
  let t_pool_info_input =
    Input {
      output_reference: t_pool_info_outref,
      output: t_pool_info_output_ada_collateral,
    }
  (t_pool_info_input, t_pool_info_datum_ada_collateral)
}

pub fn get_license_input_output() -> (Input, Output) {
  let license_input =
    Input {
      output_reference: OutputReference {
        transaction_id: #"07f157faf99b850b4971034feee28d",
        output_index: 0,
      },
      output: Output {
        address: from_script(#"12"),
        value: assets.add(
          assets.zero,
          license_symbol,
          string.to_bytearray(@"1827715600000"),
          1,
        ),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let license_output =
    Output {
      address: from_script(#"12"),
      value: assets.add(
        assets.zero,
        license_symbol,
        string.to_bytearray(@"1827715600000"),
        1,
      ),
      datum: NoDatum,
      reference_script: None,
    }
  (license_input, license_output)
}
