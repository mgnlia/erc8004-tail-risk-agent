import { ethers } from "hardhat";

async function main() {
  const Factory = await ethers.getContractFactory("TailRiskUnderwriter");
  const contract = await Factory.deploy();
  await contract.waitForDeployment();
  console.log("TailRiskUnderwriter deployed:", await contract.getAddress());
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
