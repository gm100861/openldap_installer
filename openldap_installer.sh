#!/bin/bash
## OpenLDAP simple installation script. As tested on CentOS 6.3
## This script must be run as root

hostname=`hostname`

echo "==========================================================="
echo "           This script will install OpenLDAP"
echo "It assumes that there is no OpenLDAP installed in this host"
echo "   SElinux will be disabled and firewall will be stopped"
echo "==========================================================="
echo ""
echo -n "What is the root domain? [eg mydomain.com]: "
read -p "$1" rootDN
echo -n "What is the administrator domain? [eg ldap.$rootDN or manager.$rootDN]: "
read -p "$1" adminDN
echo -n "What is the administrator password that you want to use?: "
read -p "$1" passwordDN
echo -n "Do you want to install Webmin/Do you want me to configure your Webmin LDAP modules? [Y/n]: "
read -p "$1" installWebmin

## Separate input
domain=${rootDN%.*}
tld=${rootDN#*.}
cn2=${adminDN%.*}
cn=${cn2%.*}

clear
echo "================================================================="
echo "Kindly review following details before proceed with installation:"
echo "================================================================="
echo -e "Hostname: \e[01;37m$hostname\e[00m"
echo -e "Root DN: \e[01;37mdc=$domain,dc=$tld\e[00m"
echo -e "Administrator DN: \e[01;37mcn=$cn,dc=$domain,dc=$tld\e[00m"
echo -e "Administrator Password: \e[01;37m$passwordDN\e[00m"
echo -e "Webmin installation: \e[01;37m$installWebmin\e[00m"
echo "================================================================="
echo ""
echo -n "Can I proceed with the installation? [Y/n]: "
read -p "$1" startinstall

if [ ! "$startinstall" == "Y" ]; then
        echo "Installation aborted."
        exit 1
else

        ## Stop if openldap-servers has been installed
        echo "Checking whether openldap-servers has been installed.."
        if rpm -qa | grep openldap-servers; then
                echo "openldap-servers package found. Exiting.."
                exit 1
        else
                echo "openldap-servers package not found. Proceed with installation"
        fi

        ## Disable SElinux and turn off iptables
        echo "Disabling SElinux and stopping firewall.."
        setenforce 0
        sed -i.bak 's#SELINUX=enforcing#SELINUX=disabled#g' /etc/selinux/config
        service iptables stop

        ## Install OpenLDAP using yum
        echo "Installing OpenLDAP using yum.."
        if yum install openldap-servers cronie sudo openldap openldap-clients pam_ldap nss-pam-ldapd -q -y; then
                echo "OpenLDAP installed"
        else
                echo "Error in installation"
                exit 1
        fi

        ## Configure OpenLDAP database
        echo "Configuring OpenLDAP database.."
        bdb_file='/etc/openldap/slapd.d/cn=config/olcDatabase={2}bdb.ldif'
        sed -i.bak "s#dc=my-domain,dc=com#dc=$domain,dc=$tld#g" $bdb_file
        echo "olcRootPW: $passwordDN" >> $bdb_file
        echo "olcTLSCertificateFile: /etc/openldap/certs/"$domain"_cert.pem" >> $bdb_file
        echo "olcTLSCertificateKeyFile: /etc/openldap/certs/"$domain"_key.pem" >> $bdb_file

        ## Configure monitoring privileges
        echo "Configuring monitoring privileges.."
        monitor_file='/etc/openldap/slapd.d/cn=config/olcDatabase={1}monitor.ldif'
        sed -i.bak "s#cn=manager,dc=my-domain,dc=com#cn=$cn,dc=$domain,dc=$tld#g" $monitor_file

        ## Configure database cache
        echo "Configuring database cache.."
        cp /usr/share/openldap-servers/DB_CONFIG.example /var/lib/ldap/DB_CONFIG
        chown -Rf ldap:ldap /var/lib/ldap/

        ## Generate certificate
        echo "Generating SSL.."
        [ ! -d /etc/openldap/certs ] && mkdir /etc/openldap/certs || :
        chown root:ldap /etc/openldap/certs
        openssl req -new -x509 -nodes -out /etc/openldap/certs/${domain}_cert.pem -keyout /etc/openldap/certs/${domain}_key.pem -days 365
        chown -Rf root:ldap /etc/openldap/certs/${domain}_cert.pem
        chmod -Rf 750 /etc/openldap/certs/${domain}_key.pem

        ## Configure service
        echo "Configuring LDAP service.."
        sed -i.bak "s#SLAPD_LDAPS=no#SLAPD_LDAPS=yes#g" /etc/sysconfig/ldap

        echo "Checking OpenLDAP configuration.."
        if slaptest -u; then
                echo "OpenLDAP installation done. Starting SLAPD.."
                chkconfig slapd on
                service slapd start
        else
                echo "OpenLDAP installation error. Exiting.."
                exit 1
        fi

        ## Configure client
        echo "Configuring LDAP client inside this host.."
        ldap_config='/etc/openldap/ldap.conf'
        echo "TLS_CACERT /etc/openldap/certs/"$domain"_cert.pem" > $ldap_config
        echo "URI ldap://127.0.0.1" >> $ldap_config
        echo "BASE dc=$domain,dc=$tld" >> $ldap_config

        ## Install Webmin
        if [ $installWebmin == "Y" ]; then
                echo "Checking the Webmin installation.."
                if rpm -qa | grep webmin; then
                        echo "Webmin package found in this host. I will configure the module for you."

                        ## Configure webmin module - LDAP server
                        echo "Configuring webmin LDAP server module.."
                        webmin_ldap='/etc/webmin/ldap-server/config'
                        sed -i.bak "s#/etc/openldap/slapd.conf#/etc/openldap/slapd.d#g" $webmin_ldap
                        sed -i.bak "s#/etc/init.d/ldap#/etc/init.d/slapd#g" $webmin_ldap

                        ## Configure webmin module - LDAP client
                        echo "Configuring webmin LDAP client module.."
                        webmin_ldap_client='/etc/webmin/ldap-client/config'
                        sed -i.bak "s#/etc/ldap.conf#/etc/openldap/ldap.conf#g" $webmin_ldap_client
                        echo "$passwordDN" > /etc/ldap.secret
                        echo -e "Installation completed!  [ \e[00;32mOK\e[00m ]"
                        echo "============================================================================"
                        echo "     You may need to open following port in firewall: 389, 636, 10000"
                        echo "Dont forget to refresh your Webmin module! Login to Webmin > Refresh Modules"
                        echo "============================================================================"
                else
                        echo "Webmin package not found in this host. Installing Webmin.."
                        if rpm -Uhv 'http://www.webmin.com/download/rpm/webmin-current.rpm'; then
                                echo "Webmin installed."

                                ## Configure webmin module - LDAP server
                                echo "Configuring webmin LDAP server module.."
                                webmin_ldap='/etc/webmin/ldap-server/config'
                                sed -i.bak "s#/etc/openldap/slapd.conf#/etc/openldap/slapd.d#g" $webmin_ldap
                                sed -i.bak "s#/etc/init.d/ldap#/etc/init.d/slapd#g" $webmin_ldap

                                ## Configure webmin module - LDAP client
                                echo "Configuring webmin LDAP client module.."
                                webmin_ldap_client='/etc/webmin/ldap-client/config'
                                sed -i.bak "s#/etc/ldap.conf#/etc/openldap/ldap.conf#g" $webmin_ldap_client
                                echo "$passwordDN" > /etc/ldap.secret
                                echo -e "Installation completed!  [ \e[00;32mOK\e[00m ]"
                                echo "============================================================================"
                                echo "     You may need to open following port in firewall: 389, 636, 10000"
                                echo "Dont forget to refresh your Webmin module! Login to Webmin > Refresh Modules"
                                echo "============================================================================"
                        else
                                echo "Webmin installation failed!"
                        fi
                fi
        else
                echo -e "Installation completed!  [ \e[00;32mOK\e[00m ]"
                echo "========================================================="
                echo "You may need to open following port in firewall: 389, 636"
                echo "========================================================="
        fi
fi
