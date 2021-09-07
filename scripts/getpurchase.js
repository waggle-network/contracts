const _ = require('lodash')
const { assert } = require('chai');
const { FixedNumber } = require('ethers')
const { ethers, web3 } = require('hardhat')
require('@nomiclabs/hardhat-web3')

async function main () {
  const [deployer] = await ethers.getSigners()

  console.log('Deploying contracts with the account:', deployer.address)
  console.log('Account balance:', (await deployer.getBalance()).toString())
  const FixedSwap = await ethers.getContractFactory('FixedSwap')
  const fixedSwap = await FixedSwap.attach('0xb44aeba9c226b49a40A69a2b146913E60899e76c')
  const buyes = await fixedSwap.buyers()
  console.log(buyes)
  await delay(10000)
}

const delay = (timer) => {
  return new Promise((resolve) => {
    setTimeout(() => {
      resolve()
    }, timer || 1000)
  })
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
