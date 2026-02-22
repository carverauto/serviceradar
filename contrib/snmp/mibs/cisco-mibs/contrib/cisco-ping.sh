#!/bin/sh
# V1.1
# By Michael R. MacFaden
# Cisco Systems, Inc 1997
# What? Cause a router to use TCP/IP ping another node via SNMPv1 and the
# CiscoSystems PING MIB 
# PREREQ: SNMP Research tools and snmpinfo.dat containing cisco mibs
# OS TESTED: Solaris 2.x

# include normal solaris path + SNMP tools
# uncomment this to see the command line output
#DEBUG=echo

umask 022
PATH=/usr/sbin:/usr/bin:/misc/snmpr/bin export PATH
SR_TOOLS=/misc/snmpr/bin
SR_MGR_CONF_DIR=/misc/snmpr/mibs export SR_MGR_CONF_DIR
PATH=/usr/sbin:/usr/bin:$SR_TOOLS export PATH
SETVAR=setany
GETTAB=gettab
GETONE=getone
THIS_HOST=`uname -n`
TMP_FILE=/tmp/$$-ping.tmp
# SNMP protocol version
SR_UTIL_SNMP_VERSION=-v1
export SR_UTIL_SNMP_VERSION
# SNMP comm str
# router to ping from
MYROUTER=calloway
WR_COMSTR=private
RD_COMSTR=public
SR_UTIL_COMMUNITY=$WR_COMSTR
export SR_UTIL_COMMUNITY
# set row owner id to: user@host:sw-version
if [ "$USERID" = "" ]; then
   FQDN=`ping $THIS_HOST 50 1 | awk '{print $1}'`
   ROW_OWNER="`/usr/ucb/whoami`@$FQDN:ping-mib.sh:v1.0"
fi
rm -f $TMP_FILE > /dev/null 2>&1

# check tmp file for errors
ChkErrExit()
{
  grep "^Error " $TMP_FILE > /dev/null 2>&2
  if [ $? = 0 ]; then
    echo "ERROR: verify path to router, verify SNMPv1 read & write comm=
 str."
    rm -f $TMP_FILE
    exit 1
  else
    rm -f $TMP_FILE
  fi
}

# report PING Table
SendPingReq()
{
  echo "INFO: now asking $MYROUTER to ping $HOST using protocol #$PROTOCOL..."
  $DEBUG $SETVAR $MYROUTER \
  ciscoPingEntryStatus.$$ -i 4 \
  ciscoPingEntryOwner.$$ -D $ROW_OWNER \
  ciscoPingProtocol.$$ -i $PROTOCOL \
  ciscoPingPacketSize.$$ -i $SIZE \
  ciscoPingPacketCount.$$ -i $COUNT \
  ciscoPingAddress.$$ -o $HOST 2>&1 | tee $TMP_FILE
  ChkErrExit
}

# output ping table results
# TODO: poll ciscoPingCompleted to verify operation has completed.
# for now just dump current status and exit
ReportPingResults()
{
  echo
  echo "INFO: now retrieving ping results..."
  echo
  $DEBUG $GETTAB $MYROUTER ciscoPingTable | fgrep $$ 2>&1 | tee $TMP_FILE
  if [ $? != 0 ]; then
    echo "ERROR: $GET failed. See prior error msgs."
    rm -f $TMP_FILE
    exit 1
  fi
  ChkErrExit
  echo "---------"
  echo
  echo "NOTE: if ciscoPingCompleted is not true, then keep polling for the=
 result..."
}

# check sparse table for existing entry, exit if found
CheckExisting()
{
  $DEBUG $GETONE $MYROUTER ciscpPingEntryOwner.$$ > $TMP_FILE 2>&1
  if [ $? != 0 ]; then
     # assume -1 here means entry not found.
     return 0
  fi

  HAS_ENTRY=`fgrep $$ $TMP_FILE`
  if [ "$HAS_ENTRY " != "" ]; then
    echo "ERROR: try script again, entry for $$ found in ping table."
  fi
  ChkErrExit
}

# main()
# inputs
# 1.host to ping to
HOST=$1
# 2.number of icmp echo's
COUNT=5
# 3.100 bytes
SIZE=100
# 4.Use IPv4
PROTOCOL=1
if [ "$2" != "" ]; then
  COUNT=$2
fi
if [ "$3" != "" ]; then
  SIZE=$3
fi
if [ "$4" != "" ]; then
  PROTOCOL=$4
fi

# verify  hostname passed in in dotted-quad format
if [ "$HOST" = "" ]; then
   echo "usage: $0 hostname [count] [size] [protocol]"
   echo "usage: $0 count=5, size=100,protocol=1(ip). See=
 CISCO-PING-V1SMI.my"
   exit 1
fi

# convert host to dotted-quad
QUAD=`echo $HOST | egrep "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"`
if [ "$QUAD" = "" ]; then
  HOST=`echo "$HOST\nexit" | nslookup | awk '{ if (NR == 8) print $2}'`
  if [ "$HOST" = "" ]; then
       echo "ERROR: DNS (nslookup) of hostname failed. Exiting."
       exit 1
  fi
fi

# 0. convert host to hex format hex:hex:hex:hex from dec.dec.dec.dec
HOST=`echo $HOST | awk -F. '{printf("%x:%x:%x:%x", $1, $2, $3, $4)}'`

# 1. check to see if this mib value is in use...
CheckExisting


# 2. create a new row in the conceptual ping table and cause ping to start =

# using the new pseudo-random value (this script's process id)
SendPingReq

# wait a couple of seconds for simple pings to complete
sleep 2

# 3. retrieve the value from the router
ReportPingResults

# normal exit
exit 0
