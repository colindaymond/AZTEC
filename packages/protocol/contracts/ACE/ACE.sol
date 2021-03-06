pragma solidity >=0.5.0 <0.6.0;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";

import "../interfaces/IAZTEC.sol";
import "../interfaces/IERC20.sol";

import "../libs/IntegerUtils.sol";
import "../libs/NoteUtils.sol";
import "../libs/ProofUtils.sol";
import "../libs/SafeMath8.sol";

/**
 * @title The AZTEC Cryptography Engine
 * @author AZTEC
 * @dev ACE validates the AZTEC protocol's family of zero-knowledge proofs, which enables
 *      digital asset builders to construct fungible confidential digital assets according to the AZTEC token standard.
 **/
contract ACE is IAZTEC {
    using IntegerUtils for uint256;
    using NoteUtils for bytes;
    using ProofUtils for uint24;
    using SafeMath for uint256;
    using SafeMath8 for uint8;

    // keccak256 hash of "JoinSplitSignature(uint24 proof,bytes32[4] note,uint256 challenge,address sender)"
    bytes32 constant internal JOIN_SPLIT_SIGNATURE_TYPE_HASH =
        0x904692743a9f431a791d777dd8d42e18e79888579fa6807b5f17b14020210e30;

    event SetCommonReferenceString(bytes32[6] _commonReferenceString);
    event SetProof(
        uint8 indexed epoch, 
        uint8 indexed category, 
        uint8 indexed id, 
        address validatorAddress
    );
    event IncrementLatestEpoch(uint8 newLatestEpoch);

    struct Note {
        uint8 status;
        bytes5 createdOn;
        bytes5 destroyedOn;
        address owner;
    }
    struct Flags {
        bool active;
        bool canAdjustSupply;
        bool canConvert;
    }
    struct NoteRegistry {
        IERC20 linkedToken;
        uint256 scalingFactor;
        uint256 totalSupply;
        bytes32 confidentialTotalMinted;
        bytes32 confidentialTotalBurned;
        uint256 supplementTotal;
        Flags flags;
        mapping(bytes32 => Note) notes;
        mapping(address => mapping(bytes32 => uint256)) publicApprovals;
    }

    // The commonReferenceString contains one G1 group element and one G2 group element,
    // that are created via the AZTEC protocol's trusted setup. All zero-knowledge proofs supported
    // by ACE use the same common reference string.
    bytes32[6] private commonReferenceString;

    // TODO: add a consensus mechanism! This contract is for testing purposes only until then
    address public owner;

    // Every user has their own note registry
    mapping(address => NoteRegistry) internal registries;

    // `validators`contains the addresses of the contracts that validate specific proof types
    mapping(uint8 => mapping(uint8 => mapping(uint8 => address))) public validators;

    // a list of invalidated proof ids, helpful to blacklist buggy old versions
    mapping(uint8 => mapping(uint8 => mapping(uint8 => bool))) internal disabledValidators;

    // latest proof epoch accepted by this contract
    uint8 public latestEpoch = 1;

    // keep track of validated balanced proofs
    mapping(bytes32 => bool) public validatedProofs;
    
    /**
    * @dev contract constructor. Sets the owner of ACE, the flags, the linked token address and
    *      the scaling factor.
    **/
    constructor() public {
        owner = msg.sender;
    }

    /**
    * @dev Validate an AZTEC zero-knowledge proof. ACE will issue a validation transaction to the smart contract
    *      linked to `_proof`. The validator smart contract will have the following interface:
    *      
    *      function validate(
    *          bytes _proofData, 
    *          address _sender, 
    *          bytes32[6] _commonReferenceString
    *      ) public returns (bytes)
    *
    * @param _proof the AZTEC proof object
    * @param _sender the Ethereum address of the original transaction sender. It is explicitly assumed that
    *        an asset using ACE supplies this field correctly - if they don't their asset is vulnerable to front-running
    * Unnamed param is the AZTEC zero-knowledge proof data
    * @return a `bytes proofOutputs` variable formatted according to the Cryptography Engine standard
    */
    function validateProof(
        uint24 _proof,
        address _sender,
        bytes calldata
    ) external returns (bytes memory) {
        // validate that the provided _proof object maps to a corresponding validator and also that
        // the validator is not disabled
        address validatorAddress = extractValidatorAddress(_proof);
        bytes memory proofOutputs;
        assembly {
            // the first evm word of the 3rd function param is the abi encoded location of proof data
            let proofDataLocation := add(0x04, calldataload(0x44))

            // manually construct validator calldata map
            let memPtr := mload(0x40)
            mstore(add(memPtr, 0x04), 0x100) // location in calldata of the start of `bytes _proofData` (0x100)
            mstore(add(memPtr, 0x24), _sender)
            mstore(add(memPtr, 0x44), sload(commonReferenceString_slot))
            mstore(add(memPtr, 0x64), sload(add(0x01, commonReferenceString_slot)))
            mstore(add(memPtr, 0x84), sload(add(0x02, commonReferenceString_slot)))
            mstore(add(memPtr, 0xa4), sload(add(0x03, commonReferenceString_slot)))
            mstore(add(memPtr, 0xc4), sload(add(0x04, commonReferenceString_slot)))
            mstore(add(memPtr, 0xe4), sload(add(0x05, commonReferenceString_slot)))

            // 0x104 because there's an address, the length 6 and the static array items
            let destination := add(memPtr, 0x104)
            // note that we offset by 0x20 because the first word is the length of the dynamic bytes array
            let proofDataSize := add(calldataload(proofDataLocation), 0x20)
            // copy the calldata into memory so we can call the validator contract
            calldatacopy(destination, proofDataLocation, proofDataSize)
            // call our validator smart contract, and validate the call succeeded
            let callSize := add(proofDataSize, 0x104)
            switch staticcall(gas, validatorAddress, memPtr, callSize, 0x00, 0x00) 
            case 0 {
                mstore(0x00, 400) revert(0x00, 0x20) // call failed because proof is invalid
            }

            // copy returndata to memory
            returndatacopy(memPtr, 0x00, returndatasize)

            // store the proof outputs in memory
            mstore(0x40, add(memPtr, returndatasize))
            // the first evm word in the memory pointer is the abi encoded location of the actual returned data
            proofOutputs := add(memPtr, mload(memPtr))
        }

        // if this proof satisfies a balancing relationship, we need to record the proof hash
        (, uint8 category, ) = _proof.getProofComponents();
        if (category == uint8(ProofCategory.BALANCED)) {
            uint256 length = proofOutputs.getLength();
            for (uint256 i = 0; i < length; i = i.add(1)) {
                bytes32 proofHash = keccak256(proofOutputs.get(i));
                bytes32 validatedProofHash = keccak256(abi.encode(proofHash, _proof, msg.sender));
                validatedProofs[validatedProofHash] = true;
            }
        } 
        return proofOutputs;
    }

    /**
    * @dev Clear storage variables set when validating zero-knowledge proofs.
    *      The only address that can clear data from `validatedProofs` is the address that created the proof.
    *      Function is designed to utilize [EIP-1283](https://github.com/ethereum/EIPs/blob/master/EIPS/eip-1283.md)
    *      to reduce gas costs. It is highly likely that any storage variables set by `validateProof`
    *      are only required for the duration of a single transaction.
    *      E.g. a decentralized exchange validating a swap proof and sending transfer instructions to
    *      two confidential assets.
    *      This method allows the calling smart contract to recover most of the gas spent by setting `validatedProofs`
    * @param _proof the AZTEC proof object
    * @param _proofHashes dynamic array of proof hashes
    */
    function clearProofByHashes(uint24 _proof, bytes32[] calldata _proofHashes) external {
        uint256 length = _proofHashes.length;
        for (uint256 i = 0; i < length; i = i.add(1)) {
            bytes32 proofHash = _proofHashes[i];
            require(proofHash != bytes32(0x0), "expected no empty proof hash");
            bytes32 validatedProofHash = keccak256(abi.encode(proofHash, _proof, msg.sender));
            validatedProofs[validatedProofHash] = false;
        }
    }

    /**
    * @dev Mint AZTEC notes
    *      
    * @param _proof the AZTEC proof object
    * @param _proofData the mint proof construction data
    * @param _proofSender the Ethereum address of the original transaction sender. It is explicitly assumed that
    *        an asset using ACE supplies this field correctly - if they don't their asset is vulnerable to front-running
    * Unnamed param is the AZTEC zero-knowledge proof data
    * @return two `bytes` objects. The first contains the new confidentialTotalSupply note and the second contains the
    * notes that were created. Returned so that a zkAsset can emit the appropriate events
    */
    function mint(
        uint24 _proof,
        bytes calldata _proofData,
        address _proofSender
    ) external returns (bytes memory) {
        
        NoteRegistry storage registry = registries[msg.sender];
        require(registry.flags.active == true, "note registry does not exist for the given address");
        require(registry.flags.canAdjustSupply == true, "this asset is not mintable");
        
        // Check that it's a mintable proof
        (, uint8 category, ) = _proof.getProofComponents();

        require(category == uint8(ProofCategory.MINT), "this is not a mint proof");

        bytes memory _proofOutputs = this.validateProof(_proof, _proofSender, _proofData);
        require(_proofOutputs.getLength() > 0, "call to validateProof failed");

        // Dealing with notes representing totals
        (bytes memory oldTotal,  // inputNotesTotal
        bytes memory newTotal, // outputNotesTotal
        ,
        ) = _proofOutputs.get(0).extractProofOutput();

    
        // Check the previous confidentialTotalSupply, and then assign the new one
        (, bytes32 oldTotalNoteHash, ) = oldTotal.get(0).extractNote();        

        require(oldTotalNoteHash == registry.confidentialTotalMinted, "provided total supply note does not match");
        (, bytes32 newTotalNoteHash, ) = newTotal.get(0).extractNote();
        registry.confidentialTotalMinted = newTotalNoteHash;


        // Dealing with minted notes
        (,
        bytes memory mintedNotes, // output notes
        ,
        ) = _proofOutputs.get(1).extractProofOutput();

        updateOutputNotes(mintedNotes);
        return(_proofOutputs);
    }

    /**
    * @dev Call transferFrom on a linked ERC20 token. Used in cases where the ACE's mint
    * function is called but the token balance of the note registry in question is
    * insufficient
    * @param _value the value to be transferred
    */
    function supplementTokens(uint256 _value) external {
        NoteRegistry storage registry = registries[msg.sender];
        require(registry.flags.active == true, "note registry does not exist for the given address");
        require(registry.flags.canConvert == true, "note registry does not have conversion rights");
        
        // Only scenario where supplementTokens() should be called is when a mint/burn operation has been executed
        require(registry.flags.canAdjustSupply == true, "note registry does not have mint and burn rights");
        
        require(
            registry.linkedToken.transferFrom(msg.sender, address(this), _value), 
            "transfer failed"
        );

        registry.totalSupply = registry.totalSupply.add(_value);
    }

    /**
    * @dev Burn AZTEC notes
    *      
    * @param _proof the AZTEC proof object
    * @param _proofData the burn proof construction data
    * @param _proofSender the Ethereum address of the original transaction sender. It is explicitly assumed that
    *        an asset using ACE supplies this field correctly - if they don't their asset is vulnerable to front-running
    * Unnamed param is the AZTEC zero-knowledge proof data
    * @return two `bytes` objects. The first contains the new confidentialTotalSupply note and the second contains the
    * notes that were created. Returned so that a zkAsset can emit the appropriate events
    */
    function burn(
        uint24 _proof,
        bytes calldata _proofData,
        address _proofSender
    ) external returns (bytes memory) {
        
        NoteRegistry storage registry = registries[msg.sender];
        require(registry.flags.active == true, "note registry does not exist for the given address");
        require(registry.flags.canAdjustSupply == true, "this asset is not burnable");
        
        // Check that it's a burnable proof
        (, uint8 category, ) = _proof.getProofComponents();

        require(category == uint8(ProofCategory.BURN), "this is not a burn proof");

        bytes memory _proofOutputs = this.validateProof(_proof, _proofSender, _proofData);
        
        // Dealing with notes representing totals
        (bytes memory oldTotal, // input notes
        bytes memory newTotal, // output notes
        ,
        ) = _proofOutputs.get(0).extractProofOutput();
    
        (, bytes32 oldTotalNoteHash, ) = oldTotal.get(0).extractNote();        
        require(oldTotalNoteHash == registry.confidentialTotalBurned, "provided total supply note does not match");
        (, bytes32 newTotalNoteHash, ) = newTotal.get(0).extractNote();
        registry.confidentialTotalBurned = newTotalNoteHash;


        // Dealing with burned notes
        (,
        bytes memory burnedNotes,
        ,) = _proofOutputs.get(1).extractProofOutput();


        // Although they are outputNotes, they are due to be destroyed - need removing from the note registry
        updateInputNotes(burnedNotes);
        return(_proofOutputs);
    }

    /**
    * @dev Set the common reference string.
    *      If the trusted setup is re-run, we will need to be able to change the crs
    * @param _commonReferenceString the new commonReferenceString
    */
    function setCommonReferenceString(bytes32[6] memory _commonReferenceString) public {
        require(msg.sender == owner, "only the owner can set the common reference string");
        commonReferenceString = _commonReferenceString;
        emit SetCommonReferenceString(_commonReferenceString);
    }

    /**
    * @dev Forever invalidate the given proof.
    * @param _proof the AZTEC proof object
    */
    function invalidateProof(uint24 _proof) public {
        require(msg.sender == owner, "only the owner can invalidate a proof");
        (uint8 epoch, uint8 category, uint8 id) = _proof.getProofComponents();
        disabledValidators[epoch][category][id] = true;
    }

    /**
    * @dev Validate a previously validated AZTEC proof via its hash
    *      This enables confidential assets to receive transfer instructions from a dApp that
    *      has already validated an AZTEC proof that satisfies a balancing relationship.
    * @param _proof the AZTEC proof object
    * @param _proofHash the hash of the `proofOutput` received by the asset
    * @param _sender the Ethereum address of the contract issuing the transfer instruction
    * @return a boolean that signifies whether the corresponding AZTEC proof has been validated
    */
    function validateProofByHash(
        uint24 _proof,
        bytes32 _proofHash,
        address _sender
    ) public view returns (bool) {
        bytes32 validatedProofHash = keccak256(abi.encode(_proofHash, _proof, _sender));
        return validatedProofs[validatedProofHash];
    }

    /**
    * @dev Adds or modifies a proof into the Cryptography Engine.
    *       This method links a given `_proof` to a smart contract validator.
    * @param _proof the AZTEC proof object
    * @param _validatorAddress the address of the smart contract validator
    */
    function setProof(
        uint24 _proof,
        address _validatorAddress
    ) public {
        require(msg.sender == owner, "only the owner can set a proof");
        (uint8 epoch, uint8 category, uint8 id) = _proof.getProofComponents();
        require(epoch <= latestEpoch, "the proof epoch cannot be bigger than the latest epoch");
        require(validators[epoch][category][id] == address(0x0), "existing proofs cannot be modified");
        validators[epoch][category][id] = _validatorAddress;
        emit SetProof(epoch, category, id, _validatorAddress);
    }

    /**
     * @dev Increments the `latestEpoch` storage variable.
     */
    function incrementLatestEpoch() public {
        require(msg.sender == owner, "only the owner can update the latest epoch");
        latestEpoch = latestEpoch.add(1);
        emit IncrementLatestEpoch(latestEpoch);
    }

    function createNoteRegistry(
        address _linkedTokenAddress,
        uint256 _scalingFactor,
        bool _canAdjustSupply,
        bool _canConvert
    ) public {
        require(registries[msg.sender].flags.active == false, "address already has a linked note registry");
        NoteRegistry memory registry = NoteRegistry({
            linkedToken: IERC20(_linkedTokenAddress),
            scalingFactor: _scalingFactor,
            totalSupply: 0,
            /*
            confidentialTotalMinted and confidentialTotalBurned below are the hashes of AZTEC notes 
            with k = 0 and a  =1
            */
            confidentialTotalMinted: 0xdba4b8aad5b7a3f3e8e921ae22073db70b6d6590aface862af0d4eff2b920c9d,
            confidentialTotalBurned: 0xdba4b8aad5b7a3f3e8e921ae22073db70b6d6590aface862af0d4eff2b920c9d,
            supplementTotal: 0,
            flags: Flags({
                active: true,
                canAdjustSupply: _canAdjustSupply,
                canConvert: _canConvert
            })
        });
        registries[msg.sender] = registry;
    }

    function updateNoteRegistry(
        uint24 _proof,
        address _proofSender,
        bytes memory _proofOutput
    ) public {
        NoteRegistry storage registry = registries[msg.sender];
        require(registry.flags.active == true, "note registry does not exist for the given address");
        bytes32 proofHash = keccak256(_proofOutput);
        require(
            validateProofByHash(_proof, proofHash, _proofSender) == true,
            "ACE has not validated a matching proof"
        );

        (bytes memory inputNotes,
        bytes memory outputNotes,
        address publicOwner,
        int256 publicValue) = _proofOutput.extractProofOutput();

        updateInputNotes(inputNotes);
        updateOutputNotes(outputNotes);

        if (publicValue != 0) {
            require(registry.flags.canConvert == true, "this asset cannot be converted into public tokens");

            if (publicValue < 0) {
                registry.totalSupply = registry.totalSupply.add(uint256(-publicValue));
                require(
                    registry.publicApprovals[publicOwner][proofHash] >= uint256(-publicValue),
                    "public owner has not validated a transfer of tokens"
                );
                 
                registry.publicApprovals[publicOwner][proofHash] -= uint256(-publicValue);
                require(
                    registry.linkedToken.transferFrom(publicOwner, address(this), uint256(-publicValue)), 
                    "transfer failed"
                );
            } else { 
                registry.totalSupply = registry.totalSupply.sub(uint256(publicValue));
                require(registry.linkedToken.transfer(publicOwner, uint256(publicValue)), "transfer failed");
            }
        }
    }

    /** 
    * @dev This should be called from an asset contract.
    */
    function publicApprove(address _registryOwner, bytes32 _proofHash, uint256 _value) public {
        NoteRegistry storage registry = registries[_registryOwner];
        registry.publicApprovals[msg.sender][_proofHash] = _value;
    }

    /**
    * @dev Returns the validator address for a given proof object
    */
    function getValidatorAddress(uint24 _proof) public view returns (address) {
        (uint8 epoch, uint8 category, uint8 id) = _proof.getProofComponents();
        return validators[epoch][category][id];
    }

    /**
     * @dev Returns the registry for a given address.
     */
    function getRegistry(address _owner) public view returns (
        IERC20 _linkedToken,
        uint256 _scalingFactor,
        uint256 _totalSupply,
        bytes32 _confidentialTotalMinted,
        bytes32 _confidentialTotalBurned,
        uint256 _supplementTotal,
        bool _canAdjustSupply,
        bool _canConvert,
        address aceAddress
    ) {
        NoteRegistry memory registry = registries[_owner];
        return (
            registry.linkedToken,
            registry.scalingFactor,
            registry.totalSupply,
            registry.confidentialTotalMinted,
            registry.confidentialTotalBurned,
            registry.supplementTotal,
            registry.flags.canAdjustSupply,
            registry.flags.canConvert,
            address(this)
        );
    }

    /**
     * @dev Returns the note for a given address and note hash.
     */
    function getNote(address _registryOwner, bytes32 _noteHash) public view returns (
        uint8 _status,
        bytes5 _createdOn,
        bytes5 _destroyedOn,
        address _noteOwner
    ) {
        NoteRegistry storage registry = registries[_registryOwner];
        Note storage note = registry.notes[_noteHash];
        return (
            note.status,
            note.createdOn,
            note.destroyedOn,
            note.owner
        );
    }
    
    /**
    * @dev Returns the common reference string.
    * We use a custom getter for `commonReferenceString` - the default getter created by making the storage
    * variable public indexes individual elements of the array, and we want to return the whole array
    */
    function getCommonReferenceString() public view returns (bytes32[6] memory) {
        return commonReferenceString;
    }

    function extractValidatorAddress(uint24 _proof) internal view returns (address) {
        (uint8 epoch, uint8 category, uint8 id) = _proof.getProofComponents();
        require(validators[epoch][category][id] != address(0x0), "expected the validator address to exist");
        require(disabledValidators[epoch][category][id] == false, "expected the validator address to not be disabled");
        return validators[epoch][category][id];
    }

    function updateInputNotes(bytes memory inputNotes) internal {
        uint256 length = inputNotes.getLength();
        for (uint i = 0; i < length; i = i.add(1)) {
            (address _owner, bytes32 noteHash,) = inputNotes.get(i).extractNote();
            // `note` will be stored on the blockchain
            Note storage note = registries[msg.sender].notes[noteHash];
            require(note.status == 1, "input note does not exist");
            require(note.owner == _owner, "input note owner does not match");
            note.status = uint8(2);
            // AZTEC uses timestamps to measure the age of a note, on timescales of days/months
            // The 900-ish seconds a miner can manipulate a timestamp should have little effect
            // solhint-disable-next-line not-rely-on-time
            note.destroyedOn = now.uintToBytes(5);
        }
    }

    function updateOutputNotes(bytes memory outputNotes) internal {
        uint256 length = outputNotes.getLength();
        for (uint i = 0; i < length; i = i.add(1)) {
            (address _owner, bytes32 noteHash,) = outputNotes.get(i).extractNote();
            // `note` will be stored on the blockchain
            Note storage note = registries[msg.sender].notes[noteHash];
            require(note.status == 0, "output note exists");
            note.status = uint8(1);
            // AZTEC uses timestamps to measure the age of a note on timescales of days/months
            // The 900-ish seconds a miner can manipulate a timestamp should have little effect
            // solhint-disable-next-line not-rely-on-time
            note.createdOn = now.uintToBytes(5);
            note.owner = _owner;
        }
    }
}

