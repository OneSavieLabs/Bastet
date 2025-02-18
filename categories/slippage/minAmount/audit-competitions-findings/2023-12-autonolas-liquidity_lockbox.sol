import "./library/spl_token.sol";
import "./interfaces/whirlpool.sol";

// Position struct
struct Position {
    // Whirlpool (LP pool) address, 32 bytes
    address whirlpool;
    // Position mint (liquidity NFT) address, 32 bytes
    address positionMint;
    // Position liquidity, 16 bytes
    uint128 liquidity;
    // Tick lower index, 4 bytes
    int32 tickLowerIndex;
    /// Tick upper index, 4 bytes
    int32 tickUpperIndex;
}

/// @dev The liquidity in the position cannot be practically bigger than the max of uint64 since
///      spl token functions are limited by the uint64 value.

@program_id("GUGGHzwC8wEKY3g7QS38YmoS8t5Q2faWAGAfxDK2bXbb")
contract liquidity_lockbox {
    // Orca whirlpool program address
    address public constant orca = address"whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc";
    // Whirlpool (LP) pool address
    address public pool;
    // Current program owned PDA account address
    address public pdaProgram;
    // Bridged token mint address
    address public bridgedTokenMint;
    // PDA bridged token account address
    address public pdaBridgedTokenAccount;
    // PDA header for position account
    uint64 public pdaHeader = 0xd0f7407ae48fbcaa;
    // Program PDA seed
    bytes public constant pdaProgramSeed = "pdaProgram";
    // Program PDA bump
    bytes1 public pdaBump;
    int32 public constant minTickLowerIndex = -443632;
    int32 public constant maxTickLowerIndex = 443632;

    // Total number of token accounts (even those that hold no positions anymore)
    uint32 public numPositionAccounts;
    // First available account index in the set of accounts;
    uint32 public firstAvailablePositionAccountIndex;
    // Total liquidity in a lockbox
    uint64 public totalLiquidity;

    //
    mapping(address => uint64) public mapPositionAccountLiquidity;
    mapping(address => address) public mapPositionAccountPdaAta;
    address[type(uint32).max] public positionAccounts;

    @space(10000)
    @payer(payer)
    @seed("pdaProgram")
    constructor(
        address _pool,
        address _bridgedTokenMint,
        address _pdaBridgedTokenAccount,
        @bump bytes1 _bump
    ) {
        pool = _pool;
        bridgedTokenMint = _bridgedTokenMint;
        pdaBridgedTokenAccount = _pdaBridgedTokenAccount;

        // Independently derive the PDA address from the seeds, bump, and programId
        (address pda, bytes1 bump) = try_find_program_address(["pdaProgram"], type(liquidity_lockbox).program_id);

        // Verify that the bump passed to the constructor matches the bump derived from the seeds and programId
        if (bump != _bump) {
            revert("Invalid bump");
        }

        // Assign pda and bump
        pdaProgram = pda;
        pdaBump = bump;
    }

    /// @dev Gets the position data.
    /// @param position Position account.
    /// @param positionMint Position mint (NFT).
    /// @return positionData Position data.
    function _getPositionData(AccountInfo position, address positionMint) internal view returns (Position positionData) {
        // Extract the position data
        positionData = Position({
            whirlpool: position.data.readAddress(8),
            positionMint: position.data.readAddress(40),
            liquidity: position.data.readUint128LE(72),
            tickLowerIndex: position.data.readInt32LE(88),
            tickUpperIndex: position.data.readInt32LE(92)
        });

        // Check that the liquidity is within uint64 bounds
        if (positionData.liquidity > type(uint64).max) {
            revert("Liquidity overflow");
        }

        // Check the whirlpool
        if (positionData.whirlpool != pool) {
            revert("Wrong pool address");
        }

        // Check the NFT address
        if (positionData.positionMint != positionMint) {
            revert("Wrong NFT address");
        }

        // Check tick values
        if (positionData.tickLowerIndex != minTickLowerIndex || positionData.tickUpperIndex != maxTickLowerIndex) {
            revert("Wrong ticks");
        }

        // Check the PDA ownership
        if (position.owner != orca) {
            revert("Wrong PDA owner");
        }

        // Check the PDA header data
        uint64 header = position.data.readUint64LE(0);
        if (header != pdaHeader) {
            revert("Wrong PDA header");
        }

        // Check the PDA address correctness
        (address pdaPosition, ) = try_find_program_address(["position", positionData.positionMint], orca);
        if (pdaPosition != position.key) {
            revert("Wrong position PDA");
        }
    }

    /// @dev Deposits the position mint (NFT) in order to get a corresponding liquidity amount of bridged tokens
    @mutableAccount(userPositionAccount)
    @mutableAccount(pdaPositionAccount)
    @mutableAccount(userBridgedTokenAccount)
    @mutableAccount(bridgedTokenMint)
    @account(position)
    @account(positionMint)
    @signer(userWallet)
    function deposit() external {
        // Get the position data based on provided accounts
        Position positionData = _getPositionData(tx.accounts.position, tx.accounts.positionMint.key);

        uint64 positionLiquidity = uint64(positionData.liquidity);

        // Check that the mint of the user position ATA matches the position mint
        address positionMint = tx.accounts.userPositionAccount.data.readAddress(0);
        if (positionMint != tx.accounts.positionMint.key) {
            revert("Wrong user position ATA");
        }

        // Check that the bridged token mint account is correct
        if (tx.accounts.bridgedTokenMint.key != bridgedTokenMint) {
            revert("Wrong bridged token mint account");
        }

        // PDA position account owner must be the PDA program account
        address pdaPositionOwner = tx.accounts.pdaPositionAccount.data.readAddress(32);
        if (pdaPositionOwner != pdaProgram) {
            revert("Wrong PDA position owner");
        }

        // Transfer the position NFT to the pdaPositionAccount address of this program
        SplToken.transfer(
            tx.accounts.userPositionAccount.key,
            tx.accounts.pdaPositionAccount.key,
            tx.accounts.userWallet.key,
            1);

        // Mint bridged tokens to the user
        SplToken.pda_mint_to(
            bridgedTokenMint,
            tx.accounts.userBridgedTokenAccount.key,
            pdaProgram,
            positionLiquidity,
            pdaProgramSeed,
            pdaBump);

        // Record position liquidity amount and its correspondent account address
        address positionAddress = tx.accounts.position.key;
        mapPositionAccountLiquidity[positionAddress] = positionLiquidity;
        address pdaPositionAta = tx.accounts.pdaPositionAccount.key;
        mapPositionAccountPdaAta[positionAddress] = pdaPositionAta;
        positionAccounts[numPositionAccounts] = positionAddress;

        // Increase the total number of positions
        numPositionAccounts++;
        // Increase the amount of total liquidity
        totalLiquidity += positionLiquidity;
    }

    /// @dev Withdraws LP tokens separately to each token ATA and burns provided bridge tokens.
    /// @param amount Bridged token amount.
    @mutableAccount(pool)
    @account(tokenProgramId)
    @mutableAccount(position)
    @mutableAccount(userBridgedTokenAccount)
    @mutableAccount(pdaBridgedTokenAccount)
    @mutableAccount(userWallet)
    @mutableAccount(bridgedTokenMint)
    @mutableAccount(pdaPositionAccount)
    @mutableAccount(userTokenAccountA)
    @mutableAccount(userTokenAccountB)
    @mutableAccount(tokenVaultA)
    @mutableAccount(tokenVaultB)
    @mutableAccount(tickArrayLower)
    @mutableAccount(tickArrayUpper)
    @mutableAccount(positionMint)
    @signer(sig)
    function withdraw(uint64 amount) external {
        address positionAddress = positionAccounts[firstAvailablePositionAccountIndex];
        if (positionAddress != tx.accounts.position.key) {
            revert("Wrong liquidity token account");
        }

        address pdaPositionAta = tx.accounts.pdaPositionAccount.key;
        if (mapPositionAccountPdaAta[positionAddress] != pdaPositionAta) {
            revert("Wrong position ATA");
        }

        uint64 positionLiquidity = mapPositionAccountLiquidity[positionAddress];
        // Check that the token account exists
        if (positionLiquidity == 0) {
            revert("No liquidity on a provided token account");
        }

        // Check the requested amount to be smaller or equal than the position liquidity
        if (amount > positionLiquidity) {
            revert("Amount exceeds a position liquidity");
        }

        // Check the pdaBridgedTokenAccount address
        if (tx.accounts.pdaBridgedTokenAccount.key != pdaBridgedTokenAccount) {
            revert("Wrong PDA bridged token ATA");
        }

        // Check that the pool is correct
        if (tx.accounts.pool.key != pool) {
            revert("Pool address is incorrect");
        }

        // Check that the bridged token mint account is correct
        if (tx.accounts.bridgedTokenMint.key != bridgedTokenMint) {
            revert("Wrong bridged token mint account");
        }

        // Transfer bridged tokens to the pdaBridgedTokenAccount address of this program
        SplToken.transfer(
            tx.accounts.userBridgedTokenAccount.key,
            pdaBridgedTokenAccount,
            tx.accounts.userWallet.key,
            amount);

        // Decrease the total liquidity amount
        totalLiquidity -= amount;

        // Burn acquired bridged tokens
        SplToken.pda_burn(pdaBridgedTokenAccount, bridgedTokenMint, pdaProgram, amount, pdaProgramSeed, pdaBump);

        // Decrease the position liquidity
        AccountMeta[11] metasDecreaseLiquidity = [
            AccountMeta({pubkey: pool, is_writable: true, is_signer: false}),
            AccountMeta({pubkey: SplToken.tokenProgramId, is_writable: false, is_signer: false}),
            AccountMeta({pubkey: pdaProgram, is_writable: false, is_signer: true}),
            AccountMeta({pubkey: positionAddress, is_writable: true, is_signer: false}),
            AccountMeta({pubkey: pdaPositionAta, is_writable: false, is_signer: false}),
            AccountMeta({pubkey: tx.accounts.userTokenAccountA.key, is_writable: true, is_signer: false}),
            AccountMeta({pubkey: tx.accounts.userTokenAccountB.key, is_writable: true, is_signer: false}),
            AccountMeta({pubkey: tx.accounts.tokenVaultA.key, is_writable: true, is_signer: false}),
            AccountMeta({pubkey: tx.accounts.tokenVaultB.key, is_writable: true, is_signer: false}),
            AccountMeta({pubkey: tx.accounts.tickArrayLower.key, is_writable: true, is_signer: false}),
            AccountMeta({pubkey: tx.accounts.tickArrayUpper.key, is_writable: true, is_signer: false})
        ];
        // a026d06f685b2c01 - decreaseLiquidity, eff0ae00000000000000000000000000 - amount, aaf1950200000000 - minA, b8522d0000000000 - minB
        // bytes bincode = "0xa026d06f685b2c01eff0ae00000000000000000000000000aaf1950200000000b8522d0000000000";
        // orca.call{accounts: metasDecreaseLiquidity, seeds: [[pdaProgramSeed, pdaBump]]}(bincode);
        whirlpool.decreaseLiquidity{accounts: metasDecreaseLiquidity, seeds: [[pdaProgramSeed, pdaBump]]}(amount, 0, 0);

        // Update the token remainder
        uint64 remainder = positionLiquidity - amount;
        // Update liquidity and its associated position account
        mapPositionAccountLiquidity[positionAddress] = remainder;

        // If requested amount can be fully covered by the current position liquidity, close the position
        if (remainder == 0) {
            // Update fees for the position
            AccountMeta[4] metasUpdateFees = [
                AccountMeta({pubkey: pool, is_writable: true, is_signer: false}),
                AccountMeta({pubkey: positionAddress, is_writable: true, is_signer: false}),
                AccountMeta({pubkey: tx.accounts.tickArrayLower.key, is_writable: false, is_signer: false}),
                AccountMeta({pubkey: tx.accounts.tickArrayUpper.key, is_writable: false, is_signer: false})
            ];
            whirlpool.updateFeesAndRewards{accounts: metasUpdateFees, seeds: [[pdaProgramSeed, pdaBump]]}();

            // Collect fees from the position
            AccountMeta[9] metasCollectFees = [
                AccountMeta({pubkey: pool, is_writable: true, is_signer: false}),
                AccountMeta({pubkey: pdaProgram, is_writable: false, is_signer: true}),
                AccountMeta({pubkey: positionAddress, is_writable: true, is_signer: false}),
                AccountMeta({pubkey: pdaPositionAta, is_writable: false, is_signer: false}),
                AccountMeta({pubkey: tx.accounts.userTokenAccountA.key, is_writable: true, is_signer: false}),
                AccountMeta({pubkey: tx.accounts.tokenVaultA.key, is_writable: true, is_signer: false}),
                AccountMeta({pubkey: tx.accounts.userTokenAccountB.key, is_writable: true, is_signer: false}),
                AccountMeta({pubkey: tx.accounts.tokenVaultB.key, is_writable: true, is_signer: false}),
                AccountMeta({pubkey: SplToken.tokenProgramId, is_writable: false, is_signer: false})
            ];
            whirlpool.collectFees{accounts: metasCollectFees, seeds: [[pdaProgramSeed, pdaBump]]}();

            // Close the position
            AccountMeta[6] metasClosePosition = [
                AccountMeta({pubkey: pdaProgram, is_writable: false, is_signer: true}),
                AccountMeta({pubkey: tx.accounts.userWallet.key, is_writable: true, is_signer: false}),
                AccountMeta({pubkey: positionAddress, is_writable: true, is_signer: false}),
                AccountMeta({pubkey: tx.accounts.positionMint.key, is_writable: true, is_signer: false}),
                AccountMeta({pubkey: pdaPositionAta, is_writable: true, is_signer: false}),
                AccountMeta({pubkey: SplToken.tokenProgramId, is_writable: false, is_signer: false})
            ];
            whirlpool.closePosition{accounts: metasClosePosition, seeds: [[pdaProgramSeed, pdaBump]]}();

            // Increase the first available position account index
            firstAvailablePositionAccountIndex++;
        }
    }

    /// @dev Gets the position data.
    /// @return Position data.
    @account(position)
    @account(positionMint)
    function getPositionData() external view returns (Position) {
        return _getPositionData(tx.accounts.position, tx.accounts.positionMint.key);
    }

    /// @dev Gets liquidity amounts and position accounts in order to correctly withdraw a specified liquidity amount.
    /// @param amount Liquidity amount to withdraw.
    /// @return positionAmounts Position amounts.
    /// @return positionAddresses Position mint addresses.
    /// @return positionPdaAtas Position PDA ATA-s controlled by the program.
    function getLiquidityAmountsAndPositions(uint64 amount)
        external view returns (uint64[] positionAmounts, address[] positionAddresses, address[] positionPdaAtas)
    {
        if (amount > totalLiquidity) {
            revert ("Requested amount is too big for the total available liquidity");
        }

        uint64 liquiditySum = 0;
        uint32 numPositions = 0;
        uint64 amountLeft = 0;

        // Get the number of allocated positions
        for (uint32 i = firstAvailablePositionAccountIndex; i < numPositionAccounts; ++i) {
            address positionAddress = positionAccounts[i];
            uint64 positionLiquidity = mapPositionAccountLiquidity[positionAddress];

            // Increase a total calculated liquidity and a number of positions to return
            liquiditySum += positionLiquidity;
            numPositions++;

            // Check if the accumulated liquidity is enough to cover the requested amount
            if (liquiditySum >= amount) {
                amountLeft = liquiditySum - amount;
                break;
            }
        }

        // Allocate the necessary arrays and fill the values
        positionAddresses = new address[](numPositions);
        positionAmounts = new uint64[](numPositions);
        positionPdaAtas = new address[](numPositions);
        for (uint32 i = 0; i < numPositions; ++i) {
            positionAddresses[i] = positionAccounts[firstAvailablePositionAccountIndex + i];
            positionAmounts[i] = mapPositionAccountLiquidity[positionAddresses[i]];
            positionPdaAtas[i] = mapPositionAccountPdaAta[positionAddresses[i]];
        }

        // Adjust the last position, if it was not fully allocated
        if (numPositions > 0 && amountLeft > 0) {
            positionAmounts[numPositions - 1] = amountLeft;
        }
    }

    /// @dev Gets token account balance.
    @account(account)
    function getBalance() external view returns (uint64) {
        return SplToken.get_balance(tx.accounts.account);
    }

    /// @dev Gets total supply of a provided token account.
    @account(account)
    function totalSupply() external view returns (uint64) {
        return SplToken.total_supply(tx.accounts.account);
    }
}