require("@nomicfoundation/hardhat-toolbox");
require('hardhat-deploy');
require("dotenv").config();

module.exports = {
  solidity: {
    version: "0.8.25",
    settings: {
      evmVersion: "cancun",
      optimizer: {
        enabled: true,
        runs: 1000,
      },
    },
  },
  networks: {
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 31337,//1337
    },
  },
};

