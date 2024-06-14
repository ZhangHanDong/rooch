// Copyright (c) RoochNetwork
// SPDX-License-Identifier: Apache-2.0

/// A simple demo to demonstrate how to use Bitcoin feature block hash to generate a random number.
/// Random number is very useful and frequently used in many scenarios, expecially in games.
///
/// In this example, users can request for a blind box before the given block height.
/// The block hash of the given block height will be used to generate a random number to determine the result of the blind box.
/// There are two stage for the blind box:
///   1. Request stage: users can request for the blind box before the given block height, 
///     and got a random number generated by the txn context.
///   2. Claim stage: users can claim the blind box after the given block height. With the random number generated in the request stage, 
///     and the Bitcoin block hash, the result of the blind box can be determined.
/// The box will be determined after request stage, and is not predictable, as no ones knows the block hash of the given block height in the future.

module btc_blind_box::blind_box {
    use std::option;
    use std::vector;
    use std::bcs;
    use std::hash;
    use moveos_std::signer;
    use moveos_std::tx_context;
    use moveos_std::object::{Self, Object};
    use moveos_std::account as moveos_account;
    use moveos_std::timestamp;
    use bitcoin_move::bitcoin;
    use bitcoin_move::types::Header;

    const ErrorNoPermission: u64 = 1;
    const ErrorSoldOut: u64 = 2;
    const ErrorExceedRequestDeadline: u64 = 3;
    const ErrorClaimNotStarted: u64 = 4;
    const ErrorSaleNotStarted: u64 = 5;
    const ErrorBitcoinClientError: u64 = 6;

    /// The blind box
    struct Box has key, store {
        /// The rarity of the Box.
        rarity: u64,
    }

    struct Voucher has key {
        magic_number: u128,
    }

    /// Sale status of the blind box
    struct SaleStatus has key, store {
        total_amount: u64,
        request_deadline: u64,
        claimable_start: u64,
        sold_amount: u64,
        claimed_amount: u64,
    }

    /// The project owner who can open the sale of the blind box
    /// Players can request for the blind box before the given block height `request_deadline`,
    /// and then claim the blind box after the given block height `claimable_start`.
    public fun opne_sale(owner: &signer, amount: u64, request_deadline: u64, claimable_start: u64) {
        assert!(signer::address_of(owner) == @btc_blind_box, ErrorNoPermission);

        let status_obj = object::new_named_object<SaleStatus>(SaleStatus {
            total_amount: amount,
            request_deadline: request_deadline,
            claimable_start: claimable_start,
            sold_amount: 0,
            claimed_amount: 0,
        });
        object::to_shared(status_obj);
    }

    /// Player request for the blind box, and receive a voucher, which can be used to claim the blind box after the given block height `claimable_start`.
    public fun request_box(player: &signer, sale_status: &mut Object<SaleStatus>) {
        let status = object::borrow_mut(sale_status);
        assert!(status.sold_amount < status.total_amount, ErrorSoldOut);
        assert!(latest_block_height() <= status.request_deadline, ErrorExceedRequestDeadline);
        status.sold_amount = status.sold_amount + 1;
        moveos_account::move_resource_to<Voucher>(player, Voucher { magic_number: generate_magic_number() });
    }

    /// Player claim the blind box with the voucher.
    public fun claim_box(player: &signer, sale_status: &mut Object<SaleStatus>) {
        let status = object::borrow_mut(sale_status);
        let block_height = latest_block_height();
        assert!(block_height >= status.claimable_start, ErrorClaimNotStarted);
        status.claimed_amount = status.claimed_amount + 1;

        let voucher = moveos_account::move_resource_from<Voucher>(signer::address_of(player));
        let block = bitcoin::get_block_by_height(block_height);
        assert!(option::is_some<Header>(&block), ErrorBitcoinClientError);
        let block = option::extract(&mut block);

        let box = generate_box(&block, voucher.magic_number);
        object::transfer(object::new(box), signer::address_of(player));
        let Voucher { magic_number: _ } = voucher;
    }

    fun latest_block_height(): u64 {
        let height = bitcoin::get_latest_block_height();
        assert!(option::is_some<u64>(&height), ErrorBitcoinClientError);
        option::extract<u64>(&mut height)
    }

    fun generate_magic_number(): u128 {
        // generate a random number from tx_context
        let bytes = vector::empty<u8>();
        vector::append(&mut bytes, bcs::to_bytes(&tx_context::sequence_number()));
        vector::append(&mut bytes, bcs::to_bytes(&tx_context::sender()));
        vector::append(&mut bytes, bcs::to_bytes(&tx_context::tx_hash()));
        vector::append(&mut bytes, bcs::to_bytes(&timestamp::now_milliseconds()));

        let seed = hash::sha3_256(bytes);
        let magic_number = bytes_to_u128(seed);
        magic_number
    }

    fun generate_box(block: &Header, magic_number: u128): Box {
        // generate the box with the block hash and the magic number
        let bytes = vector::empty<u8>();
        vector::append(&mut bytes, bcs::to_bytes(block));
        vector::append(&mut bytes, bcs::to_bytes(&magic_number));
        vector::append(&mut bytes, bcs::to_bytes(&tx_context::sequence_number()));
        vector::append(&mut bytes, bcs::to_bytes(&tx_context::sender()));
        vector::append(&mut bytes, bcs::to_bytes(&tx_context::tx_hash()));

        let seed = hash::sha3_256(bytes);
        let value = bytes_to_u128(seed);

        let rand_value = value % 10000; // An uniform distribution random number range in [0, 10000)

        // Infer box rarity according to the random number
        if (rand_value < 1) {
            Box { rarity: 5 }
        } else if (rand_value < 10) {
            Box { rarity: 4 }
        } else if (rand_value < 100) {
            Box { rarity: 3 }
        } else if (rand_value < 1000) {
            Box { rarity: 2 }
        } else {
            Box { rarity: 1 }
        }
    }

    fun bytes_to_u128(bytes: vector<u8>): u128 {
        let value = 0u128;
        let i = 0u64;
        while (i < 16) {
            value = value | ((*vector::borrow(&bytes, i) as u128) << ((8 * (15 - i)) as u8));
            i = i + 1;
        };
        return value
    }

    #[test_only]
    use rooch_framework::account;

    #[test_only]
    use bitcoin_move::types; 

    #[test(sender=@0x42)]
    fun test_request_and_claim(sender: &signer) {
        rooch_framework::genesis::init_for_test();
        bitcoin_move::genesis::init_for_test();
        let module_owner = account::create_account_for_testing(@btc_blind_box);

        opne_sale(&module_owner, 100, 5, 10);

        let status_obj_id = object::named_object_id<SaleStatus>();
        let status_obj = object::borrow_mut_object_shared<SaleStatus>(status_obj_id);

        let miner = rooch_framework::bitcoin_address::random_address_for_testing();
        // request box
        let block = types::fake_block_for_test(5000, miner);
        bitcoin::submit_new_block_for_test(5, block);
        request_box(sender, status_obj);
        assert!(object::borrow(status_obj).sold_amount == 1, 101);

        // claim box
        let block = types::fake_block_for_test(100000, miner);
        bitcoin::submit_new_block_for_test(10, block);
        claim_box(sender, status_obj);
        assert!(object::borrow(status_obj).claimed_amount == 1, 102);
    }

    // TODO: Add more test cases
}