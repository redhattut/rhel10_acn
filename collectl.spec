########################################################################
# RPM Information - Basic package details
########################################################################
Name:           pnc_collectl
Summary:        PNC custom package for Collectl
Version:        7.0.0
Release:        2
License:        none
Group:          pnc
#Requires:
Obsoletes:      PNC_collectl

########################################################################
# Description
########################################################################
%description
collectl - Collects data that describes the current system status.

########################################################################
# Build section
########################################################################
%build
# No build required

########################################################################
# Pre-process section
########################################################################
%pre
# No pre required

########################################################################
# Install section
########################################################################
%install
# The build system copies root/ into BUILDROOT automatically.
# No actions required here.

########################################################################
# Post-process section
########################################################################
%post

if [ "$1" -eq 1 ]; then
  echo "collectl RPM running in FRESH INSTALL mode"
else
  echo "collectl RPM running in UPGRADE mode"
fi

SRCDIR=/var/tmp/collectl-4.3.20.1/collectl

BINDIR=/usr/bin
SHRDIR=/usr/share/collectl
MANDIR=/usr/share/man/man1
SYSDDIR=/usr/lib/systemd/system
ETCDIR=/etc
INITDIR=/etc/init.d

mkdir -p $SHRDIR/util
mkdir -p $MANDIR
mkdir -p $INITDIR
mkdir -p /var/log/collectl

install -m 755 $SRCDIR/collectl                   $BINDIR/collectl
install -m 755 $SRCDIR/colmux                     $BINDIR/colmux
install -m 444 $SRCDIR/collectl.conf              $ETCDIR/collectl.conf
install -m 644 $SRCDIR/man1/collectl.1            $MANDIR/collectl.1
install -m 644 $SRCDIR/man1/colmux.1              $MANDIR/colmux.1
install -m 755 $SRCDIR/initd/collectl             $INITDIR/collectl
install -m 644 $SRCDIR/ARTISTIC                   $SHRDIR/ARTISTIC
install -m 644 $SRCDIR/COPYING                    $SHRDIR/COPYING
install -m 644 $SRCDIR/GPL                        $SHRDIR/GPL
install -m 644 $SRCDIR/RELEASE-collectl           $SHRDIR/RELEASE-collectl
install -m 755 $SRCDIR/UNINSTALL                  $SHRDIR/UNINSTALL
install -m 644 $SRCDIR/envrules.std               $SHRDIR/envrules.std
install -m 444 $SRCDIR/formatit.ph                $SHRDIR/formatit.ph
install -m 444 $SRCDIR/gexpr.ph                   $SHRDIR/gexpr.ph
install -m 444 $SRCDIR/graphite.ph                $SHRDIR/graphite.ph
install -m 444 $SRCDIR/hello.ph                   $SHRDIR/hello.ph
install -m 444 $SRCDIR/lexpr.ph                   $SHRDIR/lexpr.ph
install -m 444 $SRCDIR/misc.ph                    $SHRDIR/misc.ph
install -m 444 $SRCDIR/proctree.ph                $SHRDIR/proctree.ph
install -m 444 $SRCDIR/statsd.ph                  $SHRDIR/statsd.ph
install -m 444 $SRCDIR/vmstat.ph                  $SHRDIR/vmstat.ph
install -m 444 $SRCDIR/vmsum.ph                   $SHRDIR/vmsum.ph
install -m 444 $SRCDIR/vnet.ph                    $SHRDIR/vnet.ph
install -m 755 $SRCDIR/client.pl                  $SHRDIR/util/client.pl

install -m 644 $SRCDIR/service/collectl.service   /etc/systemd/system/collectl.service
chmod 644 /etc/systemd/system/collectl.service

echo "Verifying server is Database"
FILE='/boot/PNC_PROVISION_CONFIG'
KEY='DBTYPE'

if [ -f "$FILE" ] && grep -q ${KEY} ${FILE}; then
  echo "Database server detected; adjusting retention policy"
  sed -i 's/\-r00:00,7/\-r00:00,3/' /etc/collectl.conf
fi

systemctl daemon-reload
systemctl enable collectl
systemctl restart collectl

exit 0

########################################################################
# Pre-uninstall section
########################################################################
%preun
if [ "$1" -eq 0 ]; then
  echo "Stopping collectl service..."
  systemctl stop collectl
  systemctl disable collectl
fi

########################################################################
# Post-uninstall section
########################################################################
%postun
if [ "$1" -eq 0 ]; then
  echo "Removing collectl files and directories"

  rm -f /usr/bin/collectl
  rm -f /usr/bin/colmux
  rm -f /etc/collectl.conf
  rm -f /usr/share/man/man1/collectl.1
  rm -f /usr/share/man/man1/colmux.1
  rm -f /etc/init.d/collectl
  rm -f /etc/systemd/system/collectl.service

  echo "Removing collectl directories..."
  rm -rf /usr/share/collectl
  rm -rf /var/log/collectl

  systemctl daemon-reload
else
  echo "collectl postun: upgrade cleanup only"
fi

########################################################################
# Files section - must match exactly what root/ puts in BUILDROOT
########################################################################
%files
%defattr(-,root,root,-)
/var/tmp/collectl-4.3.20.1/collectl/collectl
/var/tmp/collectl-4.3.20.1/collectl/colmux
/var/tmp/collectl-4.3.20.1/collectl/collectl.conf
/var/tmp/collectl-4.3.20.1/collectl/man1/collectl.1
/var/tmp/collectl-4.3.20.1/collectl/man1/colmux.1
/var/tmp/collectl-4.3.20.1/collectl/initd/collectl
/var/tmp/collectl-4.3.20.1/collectl/service/collectl.service
/var/tmp/collectl-4.3.20.1/collectl/ARTISTIC
/var/tmp/collectl-4.3.20.1/collectl/COPYING
/var/tmp/collectl-4.3.20.1/collectl/GPL
/var/tmp/collectl-4.3.20.1/collectl/RELEASE-collectl
/var/tmp/collectl-4.3.20.1/collectl/UNINSTALL
/var/tmp/collectl-4.3.20.1/collectl/client.pl
/var/tmp/collectl-4.3.20.1/collectl/envrules.std
/var/tmp/collectl-4.3.20.1/collectl/formatit.ph
/var/tmp/collectl-4.3.20.1/collectl/gexpr.ph
/var/tmp/collectl-4.3.20.1/collectl/graphite.ph
/var/tmp/collectl-4.3.20.1/collectl/hello.ph
/var/tmp/collectl-4.3.20.1/collectl/lexpr.ph
/var/tmp/collectl-4.3.20.1/collectl/misc.ph
/var/tmp/collectl-4.3.20.1/collectl/proctree.ph
/var/tmp/collectl-4.3.20.1/collectl/statsd.ph
/var/tmp/collectl-4.3.20.1/collectl/vmstat.ph
/var/tmp/collectl-4.3.20.1/collectl/vmsum.ph
/var/tmp/collectl-4.3.20.1/collectl/vnet.ph

########################################################################
# Changelog
########################################################################
%changelog
