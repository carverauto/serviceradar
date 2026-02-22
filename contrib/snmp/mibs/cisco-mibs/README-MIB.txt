cisco Systems Public MIB Area
==================================

cisco's public mib area has been reorganized to make it easier for you 
to find the mibs that you need.  All SNMPv1 mibs are now in the 
subdirectory "v1".  All SNMPv2 mibs are now in the subdirectory "v2".

The suggested way to retrieve the MIBs applicable to the cisco
products that you wish to manage is as follows:

    for each product, retrieve the file supportlists/[product]/supportlist.txt.
	(or supportlists/[product]/supportlist.html for those using WWW)
    determine which mibs each product supports from the retrieved file.
    consult the v2/readme or v1/readme file for brief descriptions of the
	functionality provided by each mib.
    retrieve all mibs which provide the functionality you are interested in,
	and are applicable to the cisco products you wish to support.
    if you need the SunNet Manager OID files, retrieve those for each
	MIB from the oid directory.
    if you need the SunNet Manager schema files, retrieve those for
	each MIB from the schema directory

The following is a list of directories which are in this directory.
The file you're reading is the one named "README", in directory
pub/mibs.

===========================================================================

app_notes		directory w/ application notes for using the mibs.
archive			directory w/ mibs, oids, schema for IOS 10.0
			  and earlier releases.
contrib			directory w/ helpful mib-related scripts/files
			  (see contrib/README)
oid			directory w/ SunNet Manager OID files for the mibs.
schema			directory w/ SunNet Manager schema files for the mibs.
supportlist		directory w/ directories for each product with
			  information about which mibs that product supports. 
traps			directory w/ SunNet Manager trap files for the mibs.
v1			SNMP version 1 mibs and SNMPv1 conversions of
			  the SNMP version 2 mibs.
v2			SNMP version 2 mibs.
