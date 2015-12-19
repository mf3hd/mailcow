#!/bin/bash
if [ "$EUID" -ne 0 ]
	then echo "Please run as root"
	exit
fi

cat includes/banner
source includes/versions
source includes/functions.sh

while getopts uhUH:D:? par; do
case $par in
	h|'?')
		usage
		exit 0
		;;
	u|U)
		[[ ${par} == "U" ]] && inst_confirm_proceed="no"
		is_upgradetask="yes"
		;;
	H) sys_hostname="$OPTARG" ;;
	D) sys_domain="$OPTARG" ;;
esac
done

if [[ ${is_upgradetask} == "yes" ]]; then
	upgradetask
	echo ${mailcow_version} > /etc/mailcow_version
echo --------------------------------- >> installer.log
echo UPGRADE to ${mailcow_version} on $(date) >> installer.log
echo --------------------------------- >> installer.log
echo FuGlu version: ${fuglu_version} >> installer.log
echo --------------------------------- >> installer.log
	exit 0
fi

source mailcow.config
checksystem
checkports
checkconfig
echo
echo "    $(textb "Hostname")            ${sys_hostname}
    $(textb "Domain")              ${sys_domain}
    $(textb "FQDN")                ${sys_hostname}.${sys_domain}
    $(textb "Timezone")            ${sys_timezone}
    $(textb "mailcow MySQL")       ${my_mailcowuser}:${my_mailcowpass}@${my_dbhost}/${my_mailcowdb}
    $(textb "mailcow admin user")  ${mailcow_admin_user}
"

returnwait "Reading configuration" "System environment"

echo --------------------------------- > installer.log
echo MySQL database host: ${my_dbhost}  >> installer.log
echo --------------------------------- >> installer.log
echo MySQL mailcow database: ${my_mailcowdb} >> installer.log
echo MySQL mailcow username: ${my_mailcowuser} >> installer.log
echo MySQL mailcow password: ${my_mailcowpass} >> installer.log
echo --------------------------------- >> installer.log
echo Only set when MySQL was not available >> installer.log
echo MySQL root password: ${my_rootpw} >> installer.log
echo --------------------------------- >> installer.log
echo mailcow administrator >> installer.log
echo Username: ${mailcow_admin_user} >> installer.log
echo Password: ${mailcow_admin_pass} >> installer.log
echo --------------------------------- >> installer.log
echo FQDN: ${sys_hostname}.${sys_domain} >> installer.log
echo Timezone: ${sys_timezone} >> installer.log
echo --------------------------------- >> installer.log
echo Web root: https://${sys_hostname}.${sys_domain} >> installer.log
echo --------------------------------- >> installer.log
echo FuGlu version: ${fuglu_version} >> installer.log
echo mailcow version: ${mailcow_version} >> installer.log
echo --------------------------------- >> installer.log

installtask environment
returnwait "System environment" "Package installation"

installtask installpackages
returnwait "Package installation" "Certificate configuration"

installtask ssl
returnwait "Certificate configuration" "MySQL configuration"

installtask mysql
returnwait "MySQL configuration" "Postfix configuration"

installtask postfix
returnwait "Postfix configuration" "Dovecot configuration"

installtask dovecot
returnwait "Dovecot configuration" "FuGlu configuration"

installtask fuglu
returnwait "FuGlu configuration" "ClamAV configuration"

installtask clamav
returnwait "ClamAV configuration" "Spamassassin configuration"

installtask spamassassin
returnwait "Spamassassin configuration" "Webserver configuration"

installtask webserver
returnwait "Webserver configuration" "SOGo configuration"

installtask sogo
returnwait "SOGo configuration" "OpenDKIM configuration"

installtask opendkim
returnwait "OpenDKIM configuration" "Restarting services"

installtask restartservices
returnwait "Restarting services" "Finish installation"

echo ${mailcow_version} > /etc/mailcow_version
chmod 600 installer.log
echo
echo "`tput setaf 2`Finished installation`tput sgr0`"
echo "Logged credentials and further information to file `tput bold`installer.log`tput sgr0`."
echo
echo "Next steps:"
echo " * Backup installer.log to a safe place and delete it from your server"
echo " * Login to https://$sys_hostname.$sys_domain\" (pease use the full URL and not your IP address)"
echo "   Username: ${mailcow_admin_user}"
echo "   Password: ${mailcow_admin_pass}"
echo " * Please recheck PTR records in ReverseDNS for both IPv4 and IPv6, also verify you have setup SPF TXT records."
echo " * Please see the wiki for help @ https://github.com/andryyy/mailcow/wiki before opening an issue"
echo
