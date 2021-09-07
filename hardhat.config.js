require('@nomiclabs/hardhat-waffle')
require('@openzeppelin/hardhat-upgrades')
require('@nomiclabs/hardhat-web3')
const pks = require('./.pks.js')
// This is a sample Hardhat task. To learn how to create your own go to
// https://hardhat.org/guides/create-task.html
task('accounts', 'Prints the list of accounts', async () => {
  const accounts = await ethers.getSigners()

  for (const account of accounts) {
    console.log(account.address)
  }
})

// You need to export an object to set up your config
// Go to https://hardhat.org/config/ to learn more

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  solidity: '0.8.0',
  networks: {
    hardhat: {
      // allowUnlimitedContractSize: true,
    },
    // testnet: {
    //   url: 'https://data-seed-prebsc-1-s1.binance.org:8545',
    //   accounts: [``],
    // },
    ropsten: {
      url: 'https://eth-ropsten.alchemyapi.io/v2/4szhG-FVK337Gq63VnnPoB3VH2BLYIQE',
      accounts: pks.ropsten,
    },
  },
  settings: {
    optimizer: {
      enabled: true,
      runs: 200,
    },
  },
}
