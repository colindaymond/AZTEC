/* global artifacts, expect, contract, beforeEach, it:true */
// ### External Dependencies
const BN = require('bn.js');
const { padLeft, keccak256 } = require('web3-utils');
const truffleAssert = require('truffle-assertions');

// ### Internal Dependencies
/* eslint-disable-next-line object-curly-newline */
const { abiEncoder, note, proof, secp256k1 } = require('aztec.js');
const { constants, proofs: { JOIN_SPLIT_PROOF } } = require('@aztec/dev-utils');

const { outputCoder } = abiEncoder;

// ### Artifacts
const ACE = artifacts.require('./contracts/ACE/ACE');
const ERC20Mintable = artifacts.require('./contracts/ERC20/ERC20Mintable');
const JoinSplit = artifacts.require('./contracts/ACE/validators/joinSplit/JoinSplit');
const JoinSplitInterface = artifacts.require('./contracts/ACE/validators/joinSplit/JoinSplitInterface');
const AdjustSupply = artifacts.require('./contracts/ACE/validators/adjustSupply/AdjustSupply');
const AdjustSupplyInterface = artifacts.require('./contracts/ACE/validators/adjustSupply/AdjustSupplyInterface');

JoinSplit.abi = JoinSplitInterface.abi;
AdjustSupply.abi = AdjustSupplyInterface.abi;


contract('ACE', (accounts) => {
    describe('initialization tests', () => {
        let ace;
        beforeEach(async () => {
            ace = await ACE.new({
                from: accounts[0],
            });
        });

        it('should set the common reference string', async () => {
            await ace.setCommonReferenceString(constants.CRS, { from: accounts[0] });
            const result = await ace.getCommonReferenceString();
            expect(result).to.deep.equal(constants.CRS);
        });

        it('should set a proof', async () => {
            const aztecJoinSplit = await JoinSplit.new();
            await ace.setProof(JOIN_SPLIT_PROOF, aztecJoinSplit.address);
            const resultValidatorAddress = await ace.getValidatorAddress(JOIN_SPLIT_PROOF);
            expect(resultValidatorAddress).to.equal(aztecJoinSplit.address);
        });

        it('should not set a proof if not owner', async () => {
            await truffleAssert.reverts(ace.setProof(JOIN_SPLIT_PROOF, accounts[1], {
                from: accounts[1],
            }));
        });

        it('should not set the common reference string if not owner', async () => {
            await truffleAssert.reverts(ace.setCommonReferenceString(constants.CRS, {
                from: accounts[1],
            }));
        });
    });

    describe('joinsplit success states', () => {
        let aztecAccounts = [];
        let notes = [];
        let ace;
        let proofData;
        let proofOutput;
        let proofHash;
        let expectedOutput;

        beforeEach(async () => {
            ace = await ACE.new({
                from: accounts[0],
            });
            aztecAccounts = [...new Array(10)].map(() => secp256k1.generateAccount());
            notes = [
                ...aztecAccounts.map(({ publicKey }, i) => note.create(publicKey, i * 10)),
                ...aztecAccounts.map(({ publicKey }, i) => note.create(publicKey, i * 10)),
            ];
            await ace.setCommonReferenceString(constants.CRS);
            const aztecJoinSplit = await JoinSplit.new();
            await ace.setProof(JOIN_SPLIT_PROOF, aztecJoinSplit.address);
            const inputNotes = notes.slice(2, 4);
            const outputNotes = notes.slice(0, 2);
            const publicOwner = aztecAccounts[0].address;
            const kPublic = 40;
            ({ proofData, expectedOutput } = proof.joinSplit.encodeJoinSplitTransaction({
                inputNotes,
                outputNotes,
                senderAddress: accounts[0],
                inputNoteOwners: aztecAccounts.slice(2, 4),
                publicOwner,
                kPublic,
                validatorAddress: aztecJoinSplit.address,
            }));
            proofOutput = outputCoder.getProofOutput(expectedOutput, 0);
            proofHash = outputCoder.hashProofOutput(proofOutput);
        });

        it('should validate a join-split transaction', async () => {
            const { receipt } = await ace.validateProof(JOIN_SPLIT_PROOF, accounts[0], proofData);
            expect(receipt.status).to.equal(true);

            const hex = parseInt(JOIN_SPLIT_PROOF, 10).toString(16);
            const hashData = [
                padLeft(proofHash.slice(2), 64),
                padLeft(hex, 64),
                padLeft(accounts[0].slice(2), 64),
            ].join('');
            const validatedProofHash = keccak256(`0x${hashData}`);
            const result = await ace.validatedProofs(validatedProofHash);
            expect(result).to.equal(true);
        });

        it('validateProofByHash returns true for a previously validated proof', async () => {
            const { receipt } = await ace.validateProof(JOIN_SPLIT_PROOF, accounts[0], proofData);
            expect(receipt.status).to.equal(true);
            const result = await ace.validateProofByHash(JOIN_SPLIT_PROOF, proofHash, accounts[0]);
            expect(result).to.equal(true);
        });

        it('clearProofByHashes clears previously set proofs', async () => {
            await ace.validateProof(JOIN_SPLIT_PROOF, accounts[0], proofData);
            const firstResult = await ace.validateProofByHash(JOIN_SPLIT_PROOF, proofHash, accounts[0]);
            expect(firstResult).to.equal(true);
            await ace.clearProofByHashes(JOIN_SPLIT_PROOF, [proofHash]);
            const secondResult = await ace.validateProofByHash(JOIN_SPLIT_PROOF, proofHash, accounts[0]);
            expect(secondResult).to.equal(false);
        });
    });

    describe('note registry', async () => {
        let aztecAccounts = [];
        let notes = [];
        let ace;
        let erc20;
        let scalingFactor;
        const proofs = [];
        let proofOutputs = [];
        const tokensTransferred = new BN(100000);

        beforeEach(async () => {
            ace = await ACE.new({
                from: accounts[0],
            });
            aztecAccounts = [...new Array(10)].map(() => secp256k1.generateAccount());
            notes = [
                ...aztecAccounts.map(({ publicKey }, i) => note.create(publicKey, i * 10)),
                ...aztecAccounts.map(({ publicKey }, i) => note.create(publicKey, i * 10)),
            ];
            await ace.setCommonReferenceString(constants.CRS);
            const aztecJoinSplit = await JoinSplit.new();
            await ace.setProof(JOIN_SPLIT_PROOF, aztecJoinSplit.address);
            const publicOwner = accounts[0];
            proofs[0] = proof.joinSplit.encodeJoinSplitTransaction({
                inputNotes: [],
                outputNotes: notes.slice(0, 2),
                senderAddress: accounts[0],
                inputNoteOwners: [],
                publicOwner,
                kPublic: -10,
                validatorAddress: aztecJoinSplit.address,
            });
            proofs[1] = proof.joinSplit.encodeJoinSplitTransaction({
                inputNotes: notes.slice(0, 2),
                outputNotes: notes.slice(2, 4),
                senderAddress: accounts[0],
                inputNoteOwners: aztecAccounts.slice(0, 2),
                publicOwner: accounts[1],
                kPublic: -40,
                validatorAddress: aztecJoinSplit.address,
            });
            proofs[2] = proof.joinSplit.encodeJoinSplitTransaction({
                inputNotes: [],
                outputNotes: notes.slice(6, 8),
                senderAddress: accounts[0],
                inputNoteOwners: [],
                publicOwner: accounts[2],
                kPublic: -130,
                validatorAddress: aztecJoinSplit.address,
            });
            proofs[3] = proof.joinSplit.encodeJoinSplitTransaction({
                inputNotes: notes.slice(6, 8),
                outputNotes: notes.slice(4, 6),
                senderAddress: accounts[0],
                inputNoteOwners: aztecAccounts.slice(6, 8),
                publicOwner: accounts[2],
                kPublic: 40,
                validatorAddress: aztecJoinSplit.address,
            });
            proofs[4] = proof.joinSplit.encodeJoinSplitTransaction({
                inputNotes: [],
                outputNotes: [notes[0], notes[3]],
                senderAddress: accounts[0],
                inputNoteOwners: [],
                publicOwner: accounts[3],
                kPublic: -30,
                validatorAddress: aztecJoinSplit.address,
            });
            proofs[5] = proof.joinSplit.encodeJoinSplitTransaction({
                inputNotes: [notes[0], notes[3]],
                outputNotes: [notes[1], notes[2]],
                senderAddress: accounts[0],
                inputNoteOwners: [aztecAccounts[0], aztecAccounts[3]],
                publicOwner: accounts[3],
                kPublic: 0, // perfectly balanced...
                validatorAddress: aztecJoinSplit.address,
            });
            erc20 = await ERC20Mintable.new();
            scalingFactor = new BN(10);
            const canAdjustSupply = false;
            const canConvert = true;
            await ace.createNoteRegistry(
                erc20.address,
                scalingFactor,
                canAdjustSupply,
                canConvert,
                { from: accounts[0] }
            );

            await Promise.all(accounts.map(account => erc20.mint(
                account,
                scalingFactor.mul(tokensTransferred),
                { from: accounts[0], gas: 4700000 }
            )));
            await Promise.all(accounts.map(account => erc20.approve(
                ace.address, // address approving to spend
                scalingFactor.mul(tokensTransferred), // value to transfer
                { from: account, gas: 4700000 }
            ))); // approving tokens
            proofOutputs = proofs.map(({ expectedOutput }) => outputCoder.getProofOutput(expectedOutput, 0));
            const proofHashes = proofOutputs.map(proofOutput => outputCoder.hashProofOutput(proofOutput));
            await ace.publicApprove(
                accounts[0],
                proofHashes[0],
                10,
                { from: accounts[0] }
            );
            await ace.publicApprove(
                accounts[0],
                proofHashes[1],
                40,
                { from: accounts[1] }
            );
            await ace.publicApprove(
                accounts[0],
                proofHashes[2],
                130,
                { from: accounts[2] }
            );
            await ace.publicApprove(
                accounts[0],
                proofHashes[4],
                30,
                { from: accounts[3] }
            );
        });

        it('should update a note registry with output notes', async () => {
            const { receipt: aceReceipt } = await ace.validateProof(JOIN_SPLIT_PROOF, accounts[0], proofs[0].proofData);
            const formattedProofOutput = `0x${proofOutputs[0].slice(0x40)}`;
            const { receipt: regReceipt } = await ace.updateNoteRegistry(JOIN_SPLIT_PROOF, accounts[0], formattedProofOutput);
            expect(aceReceipt.status).to.equal(true);
            expect(regReceipt.status).to.equal(true);
        });

        it('should update a note registry by consuming input notes, with kPublic negative', async () => {
            await ace.validateProof(JOIN_SPLIT_PROOF, accounts[0], proofs[0].proofData);
            await ace.updateNoteRegistry(JOIN_SPLIT_PROOF, accounts[0], `0x${proofOutputs[0].slice(0x40)}`);
            const { receipt: aceReceipt } = await ace.validateProof(JOIN_SPLIT_PROOF, accounts[0], proofs[1].proofData);
            const formattedProofOutput = `0x${proofOutputs[1].slice(0x40)}`;
            const { receipt: regReceipt } = await ace.updateNoteRegistry(JOIN_SPLIT_PROOF, accounts[0], formattedProofOutput);
            expect(aceReceipt.status).to.equal(true);
            expect(regReceipt.status).to.equal(true);
        });

        it('should update a note registry by consuming input notes, with kPublic positive', async () => {
            await ace.validateProof(JOIN_SPLIT_PROOF, accounts[0], proofs[2].proofData);
            await ace.updateNoteRegistry(JOIN_SPLIT_PROOF, accounts[0], `0x${proofOutputs[2].slice(0x40)}`);

            const { receipt: aceReceipt } = await ace.validateProof(JOIN_SPLIT_PROOF, accounts[0], proofs[3].proofData);
            const formattedProofOutput = `0x${proofOutputs[3].slice(0x40)}`;
            const { receipt: regReceipt } = await ace.updateNoteRegistry(JOIN_SPLIT_PROOF, accounts[0], formattedProofOutput);

            expect(aceReceipt.status).to.equal(true);
            expect(regReceipt.status).to.equal(true);
        });

        it('should update a note registry with kPublic = 0', async () => {
            await ace.validateProof(JOIN_SPLIT_PROOF, accounts[0], proofs[4].proofData);
            await ace.updateNoteRegistry(JOIN_SPLIT_PROOF, accounts[0], `0x${proofOutputs[4].slice(0x40)}`);

            const { receipt: aceReceipt } = await ace.validateProof(JOIN_SPLIT_PROOF, accounts[0], proofs[5].proofData);
            const formattedProofOutput = `0x${proofOutputs[5].slice(0x40)}`;
            const { receipt: regReceipt } = await ace.updateNoteRegistry(JOIN_SPLIT_PROOF, accounts[0], formattedProofOutput);

            expect(aceReceipt.status).to.equal(true);
            expect(regReceipt.status).to.equal(true);
        });
    });
});
