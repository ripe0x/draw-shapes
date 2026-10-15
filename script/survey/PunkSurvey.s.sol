// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

interface IPunkMarket {
    function punksOfferedForSale(uint256 punkIndex)
        external
        view
        returns (bool isForSale, uint256 index, address seller, uint256 minValue, address onlySellTo);
    function punkBids(uint256 punkIndex)
        external
        view
        returns (bool hasBid, uint256 index, address bidder, uint256 value);
    function punkIndexToAddress(uint256 punkIndex) external view returns (address);
}

interface IPunkData {
    function punkAttributes(uint16 index) external view returns (string memory);
}

interface IWrappedPunks {
    function totalSupply() external view returns (uint256);
    function tokenByIndex(uint256 index) external view returns (uint256);
}

/// @notice Read-only survey of CryptoPunksMarket offers and bids and of the wrapped punk set. No broadcast.
/// Market: `START`/`END` env select the index range (default 0..10000); START=0 truncates the CSV, other values append.
/// Run: `forge script script/survey/PunkSurvey.s.sol --sig "market()"` and `--sig "wrapped()"` on a mainnet fork.
contract PunkSurvey is Script {
    IPunkMarket constant MARKET = IPunkMarket(0xb47e3cd837dDF8e4c57F05d70Ab865de6e193BBB);
    IPunkData constant DATA = IPunkData(0x16F5A35647D6F03D5D3da7b35409D65ba03aF3B2);
    IWrappedPunks constant WRAPPED = IWrappedPunks(0xb7F7F6C52F2e2fdb1963Eab30438024864c313F6);

    /// @dev Storage slots of the `punksOfferedForSale` and `punkBids` mappings in CryptoPunksMarket.
    uint256 constant OFFERS_SLOT = 12;
    uint256 constant BIDS_SLOT = 13;

    string constant MARKET_CSV = "evidence/punks/market-26170000.csv";
    string constant WRAPPED_CSV = "evidence/punks/wrapped-26170000.csv";

    function market() external {
        uint256 start = vm.envOr("START", uint256(0));
        uint256 end = vm.envOr("END", uint256(10000));
        if (start == 0) {
            vm.writeFile(MARKET_CSV, "");
            vm.writeLine(MARKET_CSV, "index,type,accessoryCount,accessories,askWei,bidWei,ownerIsWrapper");
        }
        for (uint256 i = start; i < end; i++) {
            uint256 ask;
            uint256 bid;
            // First slot of each struct holds the bool flag; the full struct is read only when it is set.
            if (vm.load(address(MARKET), keccak256(abi.encode(i, OFFERS_SLOT))) != 0) {
                (bool forSale,,, uint256 minValue, address onlySellTo) = MARKET.punksOfferedForSale(i);
                if (forSale && onlySellTo == address(0)) ask = minValue;
            }
            if (vm.load(address(MARKET), keccak256(abi.encode(i, BIDS_SLOT))) != 0) {
                (bool hasBid,,, uint256 bidValue) = MARKET.punkBids(i);
                if (hasBid) bid = bidValue;
            }
            if (ask == 0 && bid == 0) continue;
            _row(i, ask, bid);
        }
    }

    function _row(uint256 i, uint256 ask, uint256 bid) internal {
        (string memory kind, uint256 count, string memory acc) = _split(DATA.punkAttributes(uint16(i)));
        string memory owned = MARKET.punkIndexToAddress(i) == address(WRAPPED) ? "1" : "0";
        vm.writeLine(
            MARKET_CSV,
            string.concat(
                vm.toString(i), ",", kind, ",", vm.toString(count), ",", acc, ",", vm.toString(ask), ",",
                vm.toString(bid), ",", owned
            )
        );
    }

    function wrapped() external {
        vm.writeFile(WRAPPED_CSV, "");
        vm.writeLine(WRAPPED_CSV, "index,type,accessoryCount");
        uint256 n = WRAPPED.totalSupply();
        for (uint256 k = 0; k < n; k++) {
            uint256 i = WRAPPED.tokenByIndex(k);
            (string memory kind, uint256 count,) = _split(DATA.punkAttributes(uint16(i)));
            vm.writeLine(WRAPPED_CSV, string.concat(vm.toString(i), ",", kind, ",", vm.toString(count)));
        }
    }

    /// @dev "Male 2, Shadow Beard, Earring" -> ("Male 2", 2, "Shadow Beard|Earring").
    function _split(string memory attrs) internal pure returns (string memory kind, uint256 count, string memory acc) {
        bytes memory b = bytes(attrs);
        uint256 first = b.length;
        for (uint256 j = 0; j < b.length; j++) {
            if (b[j] == ",") {
                first = j;
                break;
            }
        }
        bytes memory k = new bytes(first);
        for (uint256 j = 0; j < first; j++) {
            k[j] = b[j];
        }
        kind = string(k);
        if (first >= b.length) return (kind, 0, "");
        bytes memory a = new bytes(b.length - first - 2);
        uint256 w;
        count = 1;
        for (uint256 j = first + 2; j < b.length; j++) {
            if (b[j] == "," ) {
                a[w++] = "|";
                j++; // skip the space after the comma
                count++;
            } else {
                a[w++] = b[j];
            }
        }
        bytes memory out = new bytes(w);
        for (uint256 j = 0; j < w; j++) {
            out[j] = a[j];
        }
        acc = string(out);
    }
}
