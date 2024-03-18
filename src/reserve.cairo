use starknet::ContractAddress;
use core::poseidon::PoseidonTrait;
use core::hash::{HashStateTrait, HashStateExTrait};
use core::array;
#[derive(Drop, Hash)]
struct CEXAddressBalanceStruct {
    balance_number: u256
}

#[derive(Copy, Drop, Serde)]
struct CEXConfig {
    // cex address
    erc20_token_contract_address: ContractAddress,
    // erc 20 address like ETH, DAI
    universal_erc20_address: ContractAddress
}


#[starknet::interface]
trait IERC20<TState> {
    fn balance_of(self: @TState, account: ContractAddress) -> u256;
}

#[starknet::interface]
trait IReserve<TContractState> {
    // only cex author call
    fn register_cex_details(
        ref self: TContractState,
        cex_name: felt252,
        cex_all_token_address: Array<CEXConfig>,
        cex_internal_hash: felt252
    ) -> bool;
    // only this project owner call
    fn register_cex_author(
        ref self: TContractState, cex_name: felt252, cex_author_address: ContractAddress
    );
    // anybody can call
    fn query_reserve_for_user(ref self: TContractState, cex_name: felt252) -> bool;
}


#[starknet::contract]
pub mod Reserve {
    use core::hash::HashStateTrait;
    use core::hash::HashStateExTrait;
    use core::hash::LegacyHash;
    use core::array::SpanTrait;
    use core::array::ArrayTrait;
    use core::traits::TryInto;
    use core::pedersen;
    use core::starknet::{get_caller_address, get_contract_address};
    use super::{
        IERC20, IERC20Dispatcher, IERC20DispatcherTrait, CEXAddressBalanceStruct, PoseidonTrait,
        ContractAddress, IReserve, CEXConfig
    };


    #[storage]
    struct Storage {
        owner: ContractAddress,
        cex_name_and_author: LegacyMap<felt252, ContractAddress>,
        cex_name_and_token_details: LegacyMap<felt252, Array<CEXConfig>>,
        cex_name_and_internal_hash: LegacyMap<felt252, felt252>,
        is_cex_register: LegacyMap<felt252, bool>
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.owner.write(get_caller_address());
    }

    #[abi(embed_v0)]
    impl ImplIReserve of IReserve<ContractState> {
        fn query_reserve_for_user(ref self: ContractState, cex_name: felt252) -> bool {
            let is_cex = self.is_cex_register.read(cex_name);
            assert(is_cex, 'CEX_NOT_REGISTERED');
            let cex_token_details = self.cex_name_and_token_details.read(cex_name);
            let cex_internal_hash = self.cex_name_and_internal_hash.read(cex_name);
            self.generate_cex_reserve(cex_name, cex_token_details, cex_internal_hash)
        }

        fn register_cex_details(
            ref self: ContractState,
            cex_name: felt252,
            cex_all_token_address: Array<CEXConfig>,
            cex_internal_hash: felt252
        ) -> bool {
            let is_cex = self.is_cex_register.read(cex_name);
            assert(is_cex, 'CEX_NOT_REGISTERED');
            let cex_author = self.cex_name_and_author.read(cex_name);
            assert(get_caller_address() == cex_author, 'ONLY_VALID-AUTHOR_CALL');

            self.cex_name_and_token_details.write(cex_name, cex_all_token_address);
            self.cex_name_and_internal_hash.write(cex_name, cex_internal_hash);
            self.is_cex_register.write(cex_name, true);
            true
        }

        fn register_cex_author(
            ref self: ContractState, cex_name: felt252, cex_author_address: ContractAddress
        ) {
            assert(get_caller_address() == self.owner.read(), 'ONLY_THIS_CONTRACT_OWNER_CALL');
            self.cex_name_and_author.write(cex_name, cex_author_address);
        }
    }

    #[generate_trait]
    impl InternalReserveTrait of IReserveInternalTrait {
        fn erc20_balance(
            ref self: ContractState, token_address: ContractAddress, erc20_addrs: ContractAddress
        ) -> u256 {
            let erc20_bal = IERC20Dispatcher { contract_address: token_address }
                .balance_of(erc20_addrs);
            erc20_bal
        }
        fn give_cex_on_chain_balance_hash(
            ref self: ContractState, cex_bal_struct: CEXAddressBalanceStruct
        ) -> felt252 {
            let hash = PoseidonTrait::new().update_with(cex_bal_struct).finalize();
            hash
        }

        fn generate_cex_reserve(
            ref self: ContractState,
            cex_name: felt252,
            mut cex_details: Array<CEXConfig>,
            cex_internal_hash: felt252
        ) -> bool {
            let mut final_balance: u256 = 0;
            while let Option::Some(config) = cex_details
                .pop_front() {
                    final_balance += self
                        .erc20_balance(
                            config.universal_erc20_address, config.erc20_token_contract_address
                        )
                };
            let cex_bal_struct = CEXAddressBalanceStruct { balance_number: final_balance };
            let cex_balance_hash: felt252 = self.give_cex_on_chain_balance_hash(cex_bal_struct);
            if (cex_internal_hash == cex_balance_hash) {
                true
            } else {
                false
            }
        }
    }
}

