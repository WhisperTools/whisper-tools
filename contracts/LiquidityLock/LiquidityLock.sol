// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/TokenTimelock.sol";

contract LiquidityLock is TokenTimelock {
    constructor()
        TokenTimelock(
            IERC20(0xc8Ec5B0627C794de0e4ea5d97AD9A556B361d243),
            0x8b83bBDaA7678394F62c9e9A9A314C228B210e41,
            1682380800
        )
    {}
}
