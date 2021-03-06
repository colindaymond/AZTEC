// from https://ethereum.stackexchange.com/questions/48627/how-to-catch-revert-error-in-truffle-test-javascript
const { expect } = require('chai');

const PREFIX = 'Returned error: VM Exception while processing transaction: ';

async function tryCatch(promise, message) {
    try {
        await promise;
        throw new Error();
    } catch (error) {
        expect(error, 'Expected an error but did not get one');
        expect(error.message.startsWith(PREFIX + message))
            .to.equal(true, `Expected an error starting with '${PREFIX}${message}', but got '${error.message}' instead`);
    }
}

module.exports = {
    catchRevert: async (promise) => { await tryCatch(promise, 'revert'); },
    catchOutOfGas: async (promise) => { await tryCatch(promise, 'out of gas'); },
    catchInvalidJump: async (promise) => { await tryCatch(promise, 'invalid JUMP'); },
    catchInvalidOpcode: async (promise) => { await tryCatch(promise, 'invalid opcode'); },
    catchStackOverflow: async (promise) => { await tryCatch(promise, 'stack overflow'); },
    catchStackUnderflow: async (promise) => { await tryCatch(promise, 'stack underflow'); },
    catchStaticStateChange: async (promise) => { await tryCatch(promise, 'static state change'); },
};
