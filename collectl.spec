########################################################################
# RPM Information - Basic package details
########################################################################
Name:           pnc_collectl
Summary:        PNC custom package for Collectl
Version:        7.0.0
Release:        1
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
# No build required; files are staged in /var/tmp/collectl-4.3.20.1/collectl

########################################################################
# Pre-process section
########################################################################
%pre
# No pre required

########################################################################
# Install section
########################################################################
%install
rm -rf %{buildroot}

SRCDIR=/var/tmp/collectl-4.3.20.1/collectl

BINDIR=%{buildroot}/usr/bin
DOCDIR=%{buildroot}/usr/share/doc/collectl
SHRDIR=%{buildroot}/usr/share/collectl
MANDIR=%{buildroot}/usr/share/man/man1
SYSDDIR=%{buildroot}/usr/lib/systemd/system
ETCDIR=%{buildroot}/etc
INITDIR=%{buildroot}/etc/init.d

mkdir -p $BINDIR
mkdir -p $DOCDIR
mkdir -p $SHRDIR/util
mkdir -p $MANDIR
mkdir -p $SYSDDIR
mkdir -p $INITDIR
mkdir -p %{buildroot}/var/log/collectl

install -m 755 $SRCDIR/collectl          $BINDIR/collectl
install -m 755 $SRCDIR/colmux            $BINDIR/colmux
install -m 444 $SRCDIR/collectl.conf     $ETCDIR/collectl.conf
install -m 644 $SRCDIR/man1/*            $MANDIR/
install -m 755 $SRCDIR/initd/*           $INITDIR/
install -m 644 $SRCDIR/docs/*            $DOCDIR/
install -m 644 $SRCDIR/GPL              $DOCDIR/GPL
install -m 644 $SRCDIR/ARTISTIC         $DOCDIR/ARTISTIC
install -m 644 $SRCDIR/COPYING          $DOCDIR/COPYING
install -m 644 $SRCDIR/RELEASE-collectl $DOCDIR/RELEASE-collectl
install -m 755 $SRCDIR/UNINSTALL        $SHRDIR/UNINSTALL
install -m 444 $SRCDIR/*.ph             $SHRDIR/
install -m 755 $SRCDIR/client.pl        $SHRDIR/util/client.pl
install -m 644 $SRCDIR/service/collectl.service $SYSDDIR/collectl.service

########################################################################
# Post-process section
########################################################################
%post

if [ "$1" -eq 1 ]; then
  echo "collectl RPM running in FRESH INSTALL mode"
else
  echo "collectl RPM running in UPGRADE mode"
fi

echo "Verifying server is Database"
FILE='/boot/PNC_PROVISION_CONFIG'
KEY='DBTYPE'

if [ -f "$FILE" ] && grep -q ${KEY} ${FILE}; then
  echo "Database server detected; adjusting retention policy"
  sed -i 's/\-r00:00,7/\-r00:00,3/' /etc/collectl.conf
fi

mv /usr/lib/systemd/system/collectl.service /etc/systemd/system/collectl.service
chmod 644 /etc/systemd/system/collectl.service

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
  rm -rf /usr/share/doc/collectl
  rm -rf /usr/share/collectl
  rm -rf /var/log/collectl

  systemctl daemon-reload
else
  echo "collectl postun: upgrade cleanup only"
fi

########################################################################
# Files section
########################################################################
%files
%defattr(-,root,root,-)
/usr/bin/collectl
/usr/bin/colmux
%config(noreplace) /etc/collectl.conf
/usr/share/man/man1/
/etc/init.d/collectl
/usr/share/doc/collectl/
/usr/share/collectl/
/usr/lib/systemd/system/collectl.service
/var/log/collectl

########################################################################
# Changelog
########################################################################
%changelog
