// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.9.0;

/*
    เราไม่สร้าง interface IERC20 ซ้ำ
    แต่จะ import สัญญา ERC20 ที่มีฟังก์ชันครบมาใช้งานได้โดยตรง
*/
import "./ERC20.sol";
import "./CommitReveal.sol";
import "./TimeUnit.sol";

contract RPS {
    // ------------------------------------------------
    // (A) สัญญา CommitReveal และ TimeUnit (เวอร์ชันที่ไม่เป็น abstract)
    // ------------------------------------------------
    CommitReveal private commit_reveal = new CommitReveal();
    TimeUnit private time_unit = new TimeUnit();

    // ------------------------------------------------
    // (B) สถานะของเกม
    // ------------------------------------------------
    uint public numPlayer = 0;
    uint public reward = 0;        // เก็บเป็นจำนวนโทเคนที่คอนแทรคถืออยู่
    uint public numInput = 0;
    uint public num_reveal = 0;

    uint256 constant TIMEOUT = 30;

    mapping (address => uint) public player_choice; 
    mapping (address => bytes32) public player_reveal;
    address[] public players; 
    mapping(address => bool) public player_not_played; 
    mapping(address => bool) public player_not_reveal;

    // ------------------------------------------------
    // (C) อ้างอิงถึงสัญญา ERC20 ที่ deploy ไว้
    // ------------------------------------------------
    ERC20 public token;             // ใช้ชื่อ ERC20 ตรงกับไฟล์ ERC20.sol ของคุณ
    uint256 public constant STAKE_AMOUNT = 1e12; // 0.000001 ETH = 1e12 (ถ้า decimals = 18)

    // ------------------------------------------------
    // (D) constructor รับ address ของโทเคน (ERC20) ที่มีอยู่แล้ว
    // ------------------------------------------------
    constructor(address _tokenAddress) {
        // _tokenAddress = address ของสัญญา ERC20 ที่ deploy อยู่แล้ว
        token = ERC20(_tokenAddress);
    }

    // ------------------------------------------------
    // (1) ยกเลิกข้อจำกัด 4 account => ใครก็ได้ addPlayer()
    // ------------------------------------------------
    function addPlayer() public {
        require(numPlayer < 2, "Already 2 players in game");
        if (numPlayer == 1) {
            require(msg.sender != players[0], "Same address not allowed twice");
        }

        players.push(msg.sender);
        player_not_played[msg.sender] = true;
        player_not_reveal[msg.sender] = true;
        numPlayer++;

        time_unit.setStartTime(msg.sender);
    }

    // ------------------------------------------------
    // (2)-(4) ผู้เล่นต้อง approve ให้สัญญานี้ดึง STAKE_AMOUNT ได้ 
    //         เมื่อ commit ครบ 2 => ดึงโทเคนมาเก็บในคอนแทรค
    // ------------------------------------------------
    function input(bytes32 choice) public {
        require(numPlayer == 2, "Game not full yet");
        require(player_not_played[msg.sender], "You already committed");
        require(player_not_reveal[msg.sender], "You already revealed?");

        // 1) Commit
        commit_reveal.commit(choice, msg.sender);
        player_not_played[msg.sender] = false;
        numInput++;
        time_unit.setStartTime(msg.sender);

        // 2) ถ้า commit ครบ 2 คน => ดึงโทเคนจากทั้งคู่
        if (numInput == 2) {
            address player1 = players[0];
            address player2 = players[1];

            // (3) เช็ค allowance
            require(token.allowance(player1, address(this)) >= STAKE_AMOUNT, "P1 allowance not enough");
            require(token.allowance(player2, address(this)) >= STAKE_AMOUNT, "P2 allowance not enough");

            // (4) โอนโทเคนจาก player1, player2 => เข้า RPS contract
            bool ok1 = token.transferFrom(player1, address(this), STAKE_AMOUNT);
            bool ok2 = token.transferFrom(player2, address(this), STAKE_AMOUNT);
            require(ok1 && ok2, "transferFrom failed");

            // บวกยอด reward เป็น 2*STAKE_AMOUNT
            reward = STAKE_AMOUNT * 2;
        }
    }

    // ------------------------------------------------
    // reveal => ถ้า 2 คน reveal ครบ => ตัดสินเลย
    // ------------------------------------------------
    function revealChoice(bytes32 reveal) public {
        require(numInput == 2, "Not all committed yet");

        commit_reveal.reveal(reveal, msg.sender);

        player_reveal[msg.sender] = reveal;
        player_not_reveal[msg.sender] = false;
        num_reveal++;
        time_unit.setStartTime(msg.sender);

        if (num_reveal == 2) {
            _checkWinnerAndPay();
        }
    }

    // ------------------------------------------------
    // ตัดสินผู้ชนะ => โอนโทเคนจาก contract ไปให้คนชนะ (หรือแบ่งครึ่งถ้าเสมอ)
    // ------------------------------------------------
    function _checkWinnerAndPay() private {
        bytes32 p0Choice = player_reveal[players[0]];
        bytes32 p1Choice = player_reveal[players[1]];

        uint8 p0_final_choice = uint8(uint256(p0Choice) & 0xFF);
        uint8 p1_final_choice = uint8(uint256(p1Choice) & 0xFF);

        address p0 = players[0];
        address p1 = players[1];

        if (p0_final_choice == p1_final_choice) {
            // เสมอ => แบ่งกันครึ่ง
            token.transfer(p0, reward / 2);
            token.transfer(p1, reward / 2);
        } 
        else if (_is_A_Winning(p0_final_choice, p1_final_choice)) {
            token.transfer(p0, reward);
        } 
        else {
            token.transfer(p1, reward);
        }

        emit playerChoice(p0, p0Choice, p0_final_choice);
        emit playerChoice(p1, p1Choice, p1_final_choice);

        _resetGame();
    }
    event playerChoice(address player, bytes32 reveal, uint8 finalChoice);

    // ------------------------------------------------
    // ตรวจสอบว่า choiceA ชนะ choiceB หรือไม่ (ตามกติกา RPSLS)
    // ------------------------------------------------
    function _is_A_Winning(uint8 A, uint8 B) private pure returns (bool) {
        // Rock(0), Paper(1), Scissors(2), Lizard(3), Spock(4)
        if (A == 2 && B == 1) return true; // Scissors cuts Paper
        if (A == 1 && B == 0) return true; // Paper covers Rock
        if (A == 0 && B == 3) return true; // Rock crushes Lizard
        if (A == 3 && B == 4) return true; // Lizard poisons Spock
        if (A == 4 && B == 2) return true; // Spock smashes Scissors
        if (A == 2 && B == 3) return true; // Scissors decapitates Lizard
        if (A == 3 && B == 1) return true; // Lizard eats Paper
        if (A == 1 && B == 4) return true; // Paper disproves Spock
        if (A == 4 && B == 0) return true; // Spock vaporizes Rock
        if (A == 0 && B == 2) return true; // Rock crushes Scissors
        return false;
    }

    // ------------------------------------------------
    // ฟังก์ชันดูเวลา elapsed
    // ------------------------------------------------
    function getTime() public view returns (uint256) {
        return time_unit.elapsedSeconds(msg.sender);
    }

    // ------------------------------------------------
    // (5) + (6) stopGame => timeout
    // ------------------------------------------------
    function stopGame() public {
        uint256 t = time_unit.elapsedSeconds(msg.sender);
        require(t >= TIMEOUT, "Not timed out yet");

        // กรณีไม่มีใคร reveal => ใครก็ได้มาเอาเงิน
        if (num_reveal == 0 && numPlayer == 2 && reward > 0) {
            token.transfer(msg.sender, reward);
            _resetGame();
            return;
        }

        // ตรวจว่าคนเรียกเป็น player ไหม (เว้นแต่ case ข้างบน)
        bool isPlayer = false;
        uint idxPlayer = 0;
        for(uint i = 0; i < players.length; i++){
            if(players[i] == msg.sender){
                isPlayer = true;
                idxPlayer = i;
                break;
            }
        }
        require(isPlayer, "You are not a player (or no condition matched)");

        address p = players[idxPlayer];
        address o;
        if (numPlayer == 2) {
            o = players[(idxPlayer + 1) % 2];
        }

        // (B) มี 1 คน => รับไปเลย
        if(numPlayer == 1 && reward > 0){
            token.transfer(p, reward);
            _resetGame();
        }
        // (C) 2 คน commit ไม่ครบ => แบ่งกันคนละครึ่ง
        else if(numPlayer == 2 && numInput == 1 && reward > 0){
            if(!player_not_played[p]){
                token.transfer(p, reward/2);
                token.transfer(o, reward/2);
                _resetGame();
            } else {
                revert("Please input()");
            }
        }
        // (D) 2 คน commit ครบ แต่ reveal แค่ 1 => คน reveal แบ่งกับอีกคน
        else if(numPlayer == 2 && numInput == 2 && num_reveal == 1 && reward > 0){
            if(!player_not_reveal[p]){
                token.transfer(p, reward/2);
                token.transfer(o, reward/2);
                _resetGame();
            } else {
                revert("Please revealChoice()");
            }
        }
    }

    // ------------------------------------------------
    // ล้างสถานะเกม
    // ------------------------------------------------
    function _resetGame() private {
        for (uint i = 0; i < players.length; i++) {
            address pl = players[i];
            delete player_choice[pl];
            delete player_reveal[pl];
            delete player_not_played[pl];
            delete player_not_reveal[pl];
        }
        delete players;
        numPlayer = 0;
        numInput = 0;
        num_reveal = 0;
        reward = 0;
    }
}
