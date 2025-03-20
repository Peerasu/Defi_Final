// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.2 <0.9.0;

contract CommitReveal {

  uint8 public max = 100;

  struct Commit {
    bytes32 commit;
    uint64 block;
    bool revealed;
  }

  mapping (address => Commit) public commits;

  function commit(bytes32 dataHash, address addr) public {
    commits[addr].commit = dataHash;
    commits[addr].block = uint64(block.number);
    commits[addr].revealed = false;
    emit CommitHash(addr,commits[addr].commit,commits[addr].block);
  }
  event CommitHash(address sender, bytes32 dataHash, uint64 block);

  function reveal(bytes32 revealHash, address addr) public {
    //make sure it hasn't been revealed yet and set it to revealed
    require(commits[addr].revealed==false,"CommitReveal::reveal: Already revealed");
    commits[addr].revealed=true;
    //require that they can produce the committed hash
    require(getHash(revealHash)==commits[addr].commit,"CommitReveal::reveal: Revealed hash does not match commit");
    //require that the block number is greater than the original block
    require(uint64(block.number)>commits[addr].block,"CommitReveal::reveal: Reveal and commit happened on the same block");
    //require that no more than 250 blocks have passed
    require(uint64(block.number)<=commits[addr].block+250,"CommitReveal::reveal: Revealed too late");
    //get the hash of the block that happened after they committed
    bytes32 blockHash = blockhash(commits[addr].block);
    //hash that with their reveal that so miner shouldn't know and mod it with some max number you want
    uint random = uint(keccak256(abi.encodePacked(blockHash,revealHash)))%max;
    emit RevealHash(addr,revealHash,random);
  }
  event RevealHash(address sender, bytes32 revealHash, uint random);

  function getHash(bytes32 data) public pure returns(bytes32){
    return keccak256(abi.encodePacked(data));
  }
}
