/* global artifacts, expect, contract, beforeEach, it:true */
// ### External Dependencies
const {
    abiEncoder: { outputCoder },
    secp256k1,
    note,
    proof: { adjustSupply },
} = require('aztec.js');
const { constants: { CRS } } = require('@aztec/dev-utils');
const { padLeft } = require('web3-utils');

// ### Artifacts
const ABIEncoder = artifacts.require('./contracts/ACE/validators/adjustSupply/AdjustSupplyABIEncoderTest');

contract('AdjustSupply ABI Encoder', (accounts) => {
    let adjustSupplyAbiEncoder;

    describe('success states', () => {
        beforeEach(async () => {
            adjustSupplyAbiEncoder = await ABIEncoder.new({
                from: accounts[0],
            });
        });

        it('successfully encodes output of a join split proof', async () => {
            const numNotes = 4;
            const noteValues = [50, 30, 10, 10];
            const aztecAccounts = [...new Array(numNotes)].map(() => secp256k1.generateAccount());
            const notes = aztecAccounts.map(({ publicKey }, i) => {
                return note.create(publicKey, noteValues[i]);
            });

            const inputNotes = notes.slice(0, 1);
            const outputNotes = notes.slice(1, 4);
            const publicOwner = '0x0000000000000000000000000000000000000000';

            const senderAddress = accounts[0];

            const { proofData } = adjustSupply.encodeAdjustSupplyTransaction({
                inputNotes,
                outputNotes,
                senderAddress: accounts[0],
            });

            const result = await adjustSupplyAbiEncoder.validateAdjustSupply(proofData, senderAddress, CRS, {
                from: accounts[0],
                gas: 4000000,
            });

            const expected = outputCoder.encodeProofOutputs([{
                inputNotes,
                outputNotes,
                publicOwner,
                publicValue: 0,
            }]);

            const decoded = outputCoder.decodeProofOutputs(`0x${padLeft('0', 64)}${result.slice(2)}`);

            expect(decoded[0].outputNotes[0].gamma.eq(outputNotes[0].gamma)).to.equal(true);
            expect(decoded[0].outputNotes[0].sigma.eq(outputNotes[0].sigma)).to.equal(true);
            expect(decoded[0].outputNotes[0].noteHash).to.equal(outputNotes[0].noteHash);
            expect(decoded[0].outputNotes[0].owner).to.equal(outputNotes[0].owner.toLowerCase());
            expect(decoded[0].outputNotes[1].gamma.eq(outputNotes[1].gamma)).to.equal(true);
            expect(decoded[0].outputNotes[1].sigma.eq(outputNotes[1].sigma)).to.equal(true);
            expect(decoded[0].outputNotes[1].noteHash).to.equal(outputNotes[1].noteHash);
            expect(decoded[0].outputNotes[1].owner).to.equal(outputNotes[1].owner.toLowerCase());

            expect(decoded[0].inputNotes[0].gamma.eq(inputNotes[0].gamma)).to.equal(true);
            expect(decoded[0].inputNotes[0].sigma.eq(inputNotes[0].sigma)).to.equal(true);
            expect(decoded[0].inputNotes[0].noteHash).to.equal(inputNotes[0].noteHash);
            expect(decoded[0].inputNotes[0].owner).to.equal(inputNotes[0].owner.toLowerCase());

            expect(decoded[0].publicOwner).to.equal(publicOwner.toLowerCase());
            expect(decoded[0].publicValue).to.equal(0);
            expect(result.slice(2)).to.equal(expected.slice(0x42));
            expect(result.slice(2).length / 2).to.equal(parseInt(expected.slice(0x02, 0x42), 16));
            const gasUsed = await adjustSupplyAbiEncoder.validateAdjustSupply.estimateGas(proofData, senderAddress, CRS, {
                from: accounts[0],
                gas: 4000000,
            });

            console.log('gas used = ', gasUsed);
        });
    });
});