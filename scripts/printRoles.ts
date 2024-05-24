import hre from "hardhat";

import { hashString } from "../utils/hash";

const { ethers } = hre;

const knownRoles = Object.fromEntries(
  [
    "ROLE_ADMIN",
    "TIMELOCK_ADMIN",
    "TIMELOCK_MULTISIG",
    "CONFIG_KEEPER",
    "CONTROLLER",
    "ROUTER_PLUGIN",
    "MARKET_KEEPER",
    "FEE_KEEPER",
    "ORDER_KEEPER",
    "FROZEN_ORDER_KEEPER",
    "PRICING_KEEPER",
    "LIQUIDATION_KEEPER",
    "ADL_KEEPER",
  ].map((role) => [hashString(role), role])
);

async function main() {
  const rolesConfig = await hre.gmx.getRoles();
  const accountLables = Object.fromEntries(rolesConfig.map((item) => [item.account, item.label]));
  const roleStore = await ethers.getContract("RoleStore");
  const roleCount = await roleStore.getRoleCount();
  const roles = await roleStore.getRoles(0, roleCount);

  for (const role of roles) {
    const roleMemberCount = await roleStore.getRoleMemberCount(role);
    const roleMembers = await roleStore.getRoleMembers(role, 0, roleMemberCount);
    console.log(
      "%s:\n\t%s",
      knownRoles[role] || role,
      roleMembers
        .map((account: string) => {
          const label = accountLables[account];
          if (label) {
            return `${account} (${label})`;
          }
          return account;
        })
        .join("\n\t")
    );
  }
}

main()
  .then(() => {
    console.log("done");
  })
  .catch((ex) => {
    console.error(ex);
    process.exit(1);
  });
