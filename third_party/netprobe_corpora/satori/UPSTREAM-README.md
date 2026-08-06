# satori
Python rewrite of passive OS fingerprinting tool.

It currently supports fingerprinting by the following means:
- DHCP
- DNS
- HTTP (User Agent and Server) *check out satori-ua note below
- NTP
- SMB (TCP and UDP, though limited usefulness with nobody running SMBv1 anymore)
- SSH
- SSL (JA3/JA3S/JA4)
- TCP

This program was started back in 2004 and had a decent life as a windows program, doing passive OS fingerprinting for 10 years with regular updates, but it fell by the wayside.  It has been a goal to get it back out here, written in something that I could share the code with others.  

I am NOT a programmer, I hack code together, so this is what it is.  Time permitting I'll continue to bring new modules (and have over the last 5+ years) into this that were in the windows version and more importantly update the fingerprint files.

## standalone app
satori-ua.py, it uses the fingerprint database, but I needed somethign that was reliable to determine OS on a number of occasions and figured may as well use a DB that I had!  Feed it a useragent by itself or a file full of them.

## interesting notes
Verified it appears to run fine on Risc V Architecture on the VisionFive 2 at least with no mods.

## ssl - if you want more 3rd party fingerprints
The current SSL fingerprints, in the xml ssl.xml are primarily from sslbl.abuse.ch/ja3-fingerprints, or ones I've found in my testing over the years.

To download additional ssl 3rd party fingerprints you can do:
- j3er.com - 'python3 satori.py --ja3update' 
- trisulnsm - 'python3 satori.py  --trisulnsm'

The j3er ones haven't been updated in years and it is unknown if the trisulnsm ones are being updated anymore either.  Please be aware with both that satori is going to ignore the cert when it goes to download this, if you are not comfortable with that grab the files manually and drop it in the fingerprint directory.

## requirements
### os related
- libpcap-dev

Note:  Windows install - While this should probably work on windows like any other python3 program, I've never figured out how to get the pcap header files properly installed there/seen by python, though I haven't tried in years either.  So for now, recommendation is to install on linux.

### os related (may not be needed on all os versions/distros)
- python3-dev 

### python related
#### required
- python3 (will not run on python2 due to some of the other python packages)
- pypacker*
- pcapyplus* 
- untangle*
- requests*  

#### optional
- netifaces* (while not specifically needed saves some error messages depending on distro)

#### retired/historic
- pcapy*  (Due to problems with pcapy I would recommend pcapyplus instead - depending on distro may need these installed prior:libpcap-dev, python3-dev; along with setuptools if using pip3 to install)

*(if you use pip to install it, remember to use pip3)

## updates:

periodically get the latest fingerprint files and any updates:
- git pull

## use:
- python3 satori.py -r [some pcap] -m [one of the modules]
- python3 satori.py -i [some interface] -m [one of the modules]

modules feature is optional

If you are using the interface option, this has to be run as root in most/all cases, so there are potential risks.

## graylog
I'm only a novice working with graylog, but feeding satori logs into it is much faster for processing through them after the fact than grep!

You can do things like " NOT os_guess:* " to find devices that satori was unable to provide a guess at the OS.

The content pack currently contains about 5 rules to properly parse the data.  It may not be ideal on how they are configured, I've spent a very limited amount of timing with graylog!  It has worked well enough for what I've done in testing.  nxlog would probably be a good way to inject them into graylog, but to date I've just used netcat and pushed them into a raw tcp listener!

## version
This currently really is version 0.1 of this.  Just to reiterate I am not a programmer, expecially in python, I just hack stuff together, so you have been warned.  But with that said, seems stable at this point and I've been running it in production like systems since I put this out here!

If you want to know version of individual modules you can do
- python3 satori.py --version

It will just give you a date of when that module was last updated along with what version of the 3rd party modules you're running that satori sees.
