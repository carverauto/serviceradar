# Cisco Systems Public MIB Area
Various Public Simple Network Management Protocol (SNMP) management information bases (MIBs) from Cisco Systems.

---

### :exclamation: Disclaimer
- This Repo is a mirror of various internal MIB files from various Cisco Repos. 
- All changes **MUST** be modified at the source and then replicated out to this repo.
  - For contributing, issues, or pull requests. Please review the [CONTRIBUTING.md](https://github.com/cisco/cisco-mibs/blob/main/CONTRIBUTING.md) file.

---

### :book: Usage Guidelines
The suggested way to retrieve the MIBs applicable to the Cisco products that you wish to manage is as follows:
1. For each product, download and open the desired [Support List](https://github.com/cisco/cisco-mibs/tree/main/supportlists) file:
   - `supportlists/[product]/supportlist.txt`
   - `supportlists/[product]/supportlist.html` (Download. Then open locally.)
   - `https://cisco.github.io/cisco-mibs/supportlists/[product]/supportlist.html`
     - e.g: https://cisco.github.io/cisco-mibs/supportlists/nexus9000/Nexus9000MIBSupportList.html
	 - Tip: Replace `ftp://ftp.cisco.com/pub/mibs/` in any saved URL with `https://cisco.github.io/cisco-mibs/` to view in the Browser.
2. Determine which MIBs each product supports from the retrieved file.
   - Consult the `v2/readme` or `v1/readme` file for brief descriptions of the functionality provided by each MIB.
3. Retrieve all MIBs which provide the functionality you are interested in, and are applicable to the Cisco products you wish to support.
   - Example: Download [SNMPv2-MIB.my](https://raw.githubusercontent.com/cisco/cisco-mibs/main/v2/SNMPv2-MIB.my) as per [ASR1000 Support List](https://cisco.github.io/cisco-mibs/supportlists/asr1000/asr1000-supportlist.html)
   - If you are looking for a specific file click “Go to File” and [search for the filename](https://docs.github.com/en/search-github/searching-on-github/finding-files-on-github).
     - Tip: You may also use Cisco Feature Navigator to find the desired MIB hosted in this Repo: https://cfnng.cisco.com/mibs

---

### :file_folder: Directory Structure
- `app_notes` directory with application notes for using the MIBs.
- `archive` directory with MIBs, OIDs, schema for IOS 10.0 and earlier releases.
- `contrib` directory with helpful mib-related scripts/files.
- `IE1000-MIBS` directory with IE1000 MIBs.
- `ME1200-MIBS` directory with ME1200 MIBs.
- `oid` directory with SunNet Manager OID files for the MIBs.
- `schema` directory with SunNet Manager schema files for the MIBs.
- `STRATIX2500-MIBS` directory with STRATIX2500 MIBs.
- `supportlist` directory with directories for each product with information about which MIBs that product supports. 
- `traps` directory with SunNet Manager trap files for the MIBs.
- `ucs-C-Series-mibs` directory with UCS C-Series MIBs.
- `ucs-mibs` directory with other UCS related MIBs.
- `v1` SNMP version 1 MIBs and SNMPv1 conversions of the SNMP version 2 MIBs.
- `v2` SNMP version 2 MIBs.
- `viptela-mibs` directory with Viptela MIBs.

---

### :speech_balloon: Other Notes
- This GitHub repository started as a 2/28/2022 backup of the public `ftp://ftp.cisco.com/pub/mibs/`
  - Empty folders have not been backed up.
- On 10/15/2022 `ftp.cisco.com` has been officially decommissioned making this the new source for Cisco MIB files.
  - Cisco Developers will continue maintain MIB files in this location as they did on `ftp.cisco.com`
- Other product MIBs are located on the applicable [software.cisco.com](https://software.cisco.com/download/home) downloads page. 
  - e.g. [3504 Wireless Controller, Release 8.10.162.0 MIBs](https://software.cisco.com/download/home/286312601/type/280775088/release/8.10.162.0)
  - e.g. [Firepower 4100, Release 2.12.0.432 MIBs](https://software.cisco.com/download/home/286305187/type/286287263/release/2.12.0.432)
- All instances of `ftp://ftp.cisco.com/pub/mibs/` have been replaced with `https://raw.githubusercontent.com/cisco/cisco-mibs/main/` within `.html`/`.htm` files.
