// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/0817db4a618d975648e018222aedcdeb1206959e/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { ReservoirAquaIntegrationTest } from "../test/integration/ReservoirAqua.t.sol";

/// @notice Six-line, RPC-free presentation of the tested local hero scenario.
contract Demo is Script {
    function run() external {
        ReservoirAquaIntegrationTest scenario = new ReservoirAquaIntegrationTest();
        scenario.setUp();
        ReservoirAquaIntegrationTest.HeroResult memory result = scenario.runHeroScenario();

        ReservoirAquaIntegrationTest failureScenario = new ReservoirAquaIntegrationTest();
        failureScenario.setUp();
        bool forcedFailureSurvived = failureScenario.runBrokenReinvestScenario();
        require(result.reinvestSucceeded && forcedFailureSurvived, "demo reinvest assertion failed");

        console2.log("Vault NAV before -> after", result.navBefore, result.navAfter);
        console2.log("Requested input", result.requestedInput);
        console2.log("Candidate output", result.candidateOutput);
        console2.log("Safely deliverable output", result.safeCapacity);
        console2.log("Actual input / output", result.actualInput, result.actualOutput);
        console2.log("Reinvestment result", "success; forced failure survived");
    }
}
