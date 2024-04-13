module 0x1::BetInstantiation {
    use sui::coin::{Coin, Self};
    use sui::tx_context::TxContext;
    use sui::object::ID;
    use sui::time::Time;
    use sui::address::address;
    use sui::vector::Vector;
    use sui::string::String;

    struct LockedFunds has key {
        funds: Coin,
    }

    struct AllBets has key {
        bets: vector<Bet>,
    }

    struct ApprovedUsers has key {
        users: vector<address>,
    }

    struct InitializationCap has key {
        instantiator: address,
    }   

    // Bet object structure
    struct Bet has key {
        creator_address: address,
        consenting_address: address,
        question: String,
        amount_staked: Coin,
        transaction_id: ID,
        odds: u64,
        agreed_by_both: bool,
        side_of_creator: bool, // "true" or "false", specifies in question which side is represented by "true"
        game_start_time: u64,
        game_end_time: u64,
        is_active: bool
    }

    //initialize the module, which only one address can before no others are able to 
    public fun initialize_contract(ctx: &mut TxContext) {
        //check if initialization already occured
        assert!(!exists<InitializationCap>(0x1), 503); 

        // initialize AllBets
        let all_bets = AllBets { bets: Vector::empty::<Bet>() };
        move_to(0x1, all_bets);

        // initialize ApprovedUsers
        let approved_users = ApprovedUsers { users: Vector::empty::<address>() };
        move_to(0x1, approved_users);

        let creator_address = TxContext::sender(ctx);
        //Store initialization cap at 0x1
        let init_cap = InitializationCap {
            creator_address
        };
        move_to(0x1, init_cap); 

        let coin = Coin::mint(0);
        //initialize locked funds
        let locked_funds = LockedFunds {
            coin,
        };
        move_to(0x1, locked_funds)
    }

    //create a new Bet object
    public fun create_bet(ctx: &mut TxContext, consenting_address: address,
        question: String, amount: u64,
        odds: u64, side_of_creator: String,
        game_start_time: u64, game_end_time: u64
    ) acquires AllBets {
        let creator_address = TxContext::sender(ctx);
        let transaction_id = TxContext::id(ctx);
        let amount_staked = Coin::withdraw(ctx, amount);
        let new_bet = Bet {
            creator_address,
            consenting_address,
            question,
            amount_staked,
            transaction_id,
            odds,
            agreed_by_both: false, // Initially false until second party agrees
            game_start_time,
            game_end_time,
            is_active: true // Bet is active but not yet agreed upon
            //we assume side of creator is whatever the String bet's phrase is
            //example: bet String descriptions should 
            //be phrased as "Eagles will win vs. the Seahawks today", then creator has side 'Eagles win'
        };
        
        let all_bets = borrow_global_mut<AllBets>(0x1);
        Vector::push_back(&mut all_bets.bets, new_bet);
    }

    // delete a bet if it;s not agreed upon
    public fun delete_bet(ctx: &mut TxContext, transaction_id: ID) {
        let all_bets = borrow_global_mut<AllBets>(0x1);
        let index = find_bet_index(&all_bets.bets, transaction_id);

        assert!(Vector::is_valid_index(&all_bets.bets, index), 404);
        let bet = Vector::borrow(&all_bets.bets, index);
        assert!(bet.creator_address == TxContext::sender(ctx), 403);
        assert!(!bet.agreed_by_both, 400);

        let locked_funds = borrow_global_mut<LockedFunds>(0x1);

        // Withdraw staked amount from locked funds
        let payout = Coin::withdraw(&mut locked_funds.funds, bet.amount_staked.value());
        Coin::deposit(TxContext::sender(ctx), payout);

        // Remove bet
        Vector::remove(&mut all_bets.bets, index);
    }

    //second player in instantiated bet agrees to it here
    public fun agree_to_bet(ctx: &mut TxContext, transaction_id: ID) acquires Bet, LockedFunds {
        let current_time = Time::now_microseconds();

        let all_bets = borrow_global_mut<AllBets>(0x1);
        let index = find_bet_index(&all_bets.bets, transaction_id);

        assert!(Vector::is_valid_index(&all_bets.bets, index), 404);
        let bet = Vector::borrow(&all_bets.bets, index);

        //caller is consenting address and bet is not already agreed to
        assert!(bet.consenting_address == TxContext::sender(ctx), 403); // 403: Forbidden, not consenting address
        assert!(!bet.agreed_by_both, 400); // 400: Bad Request, bet already agreed upon
        //after bet consent/start deadline
        assert!(current_time < bet.game_start_time, 408); // 408: Request Timeout, the window for agreeing to the bet has passed
        //consenting player tokens to storage
        let funds_to_lock = Coin::withdraw(ctx, bet.amount_staked.value());
        let locked_funds = LockedFunds { funds: funds_to_lock };
        
        bet.agreed_by_both = true;
    }

    // handle expiration of a bet agreement window
    public fun handle_expired_bet(ctx: &mut TxContext, transaction_id: ID) acquires Bet {
        let current_time = Time::now_microseconds();
        let index = find_bet_index(transaction_id); 
        let mut all_bets = get_all_bets(); 
        
        // Check if the bet exists
        assert!(Vector::is_valid_index(&all_bets, index), 404);

        let bet = Vector::borrow_mut(&mut all_bets, index);
        // if time past end time and no agreement, remove this bet
        if (current_time >= bet.game_end_time && !bet.agreed_by_both) {
            Coin::deposit(bet.creator_address, bet.amount_staked);
            bet.is_active = false;
            Vector::remove(&mut all_bets, index);
        }
    }

    //after game end time, send bet to oracle for winner verification
    public fun send_bet_to_oracle(ctx: &mut TxContext, bet_id: ID) {
        let all_bets = borrow_global<AllBets>(0x1);
        let index = find_bet_index(&all_bets.bets, bet_id);
        assert!(Vector::is_valid_index(&all_bets.bets, index), 404);

        let bet = Vector::borrow(&all_bets.bets, index);
        let current_time = Time::now_microseconds();

        //Only correct creator/second party can call this, and after bet end time
        assert!((TxContext::sender(ctx) == bet.creator_address || TxContext::sender(ctx) == bet.consenting_address) &&
                current_time > bet.game_end_time, 403);

        //AUSTIN TO DEFINE THIS
        send_to_oracle(bet_id, bet.question);
    }

    //after oracle finished, get the winner and perform payout
    public fun process_oracle_answer(ctx: &mut TxContext, bet_id: ID, oracle_answer: bool) {
        let all_bets = borrow_global_mut<AllBets>(0x1);
        let index = find_bet_index(&all_bets.bets, bet_id);
        assert!(Vector::is_valid_index(&all_bets.bets, index), 404);

        let bet = Vector::borrow_mut(&all_bets.bets, index);

        let winner_address = if oracle_answer { bet.creator_address } else { bet.consenting_address };

        let payout_amount = bet.amount_staked.value();
        let winning_funds = Coin::mint(payout_amount);
        Coin::deposit(winner_address, winning_funds);

        bet.is_active = false;
    }

    //find index of a bet in AllBets (unfortunately O(n))
    fun find_bet_index(all_bets: &vector<Bet>, transaction_id: ID): u64 {
        let len = Vector::length(all_bets);
        let mut index: u64 = 0;

        while (index < len) {
            if (Vector::borrow(all_bets, index).transaction_id == transaction_id) {
                return index;
            };
            index = index + 1;
        };
        // If the transaction_id not found, return out of bounds index
        len 
    }

    // Initializes the AllBets resource and publishes it under account.
    public fun initialize_bets_storage(ctx: &mut TxContext) {
        let bets = AllBets { bets: Vector::empty<Bet>() };
        move_to(&mut ctx, bets);
    }
}
