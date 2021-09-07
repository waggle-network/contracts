const hre = require("hardhat");

async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile 
  // manually to make sure everything is compiled
  // await hre.run('compile');

  // We get the contract to deploy
  const Greeter = await hre.ethers.getContractFactory("Token");
  const greeter = await Greeter.deploy("IDO Token", "IDO", 18);
  const greeter2 = await Greeter.deploy("USDT", "USDT", 6);
  const greeter3 = await Greeter.deploy("LP TOKEN", "LP", 18);

  await greeter.deployed();
  await greeter2.deployed();
  await greeter3.deployed();

  console.log("Greeter deployed to:", greeter.address, greeter2.address, greeter3.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
