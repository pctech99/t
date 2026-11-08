#!/bin/sh
# ASUS Tarkin, Skywalker ChromeOS 152.0.7977.132 (16765.51.0).
set -eu
umask 077

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

confirm() {
    printf '%s [taper oui] ' "$1"
    read -r answer </dev/tty && [ "$answer" = oui ] || die 'Operation annulee.'
}

check_install_state() {
    owned=$(device_management_client --action=enterprise_owned_get_status)
    attributes=$(device_management_client --action=install_attributes_get_status)
    fwmp=$(device_management_client --action=get_firmware_management_parameters)
    printf '%s\n' "$owned" | grep -Fxq 'EnterpriseOwnedGetStatus(): 0' &&
        [ "$attributes" = FIRST_INSTALL ] &&
        printf '%s\n' "$fwmp" | grep -Fxq 'flags=0x00000000' ||
        die 'Etat inattendu. Reprendre depuis la configuration initiale apres Emudhroll, sans continuer dans l assistant.'
}

software_wp() {
    wp=$(futility flash --wp-status --ignore-hw)
    case "$wp" in
        *'WP status: disabled') printf '%s\n' disabled ;;
        *'WP status: enabled') printf '%s\n' enabled ;;
        *) die 'Etat de la protection logicielle inconnu.' ;;
    esac
}

same_file() {
    first=$(sha256sum "$1") && second=$(sha256sum "$2") &&
        [ "${first%% *}" = "${second%% *}" ]
}

outside_vpd() {
    [ "$(wc -c < "$1")" -eq 8388608 ] || return 1
    # Tarkin ROM: RO_VPD occupies [0x3f8000, 0x400000).
    dd if="$1" of="$2.prefix" bs=4096 count=1016 2>>"$log" &&
        dd if="$1" of="$2.tail" bs=4194304 skip=1 2>>"$log"
}

read_vpd() {
    vpd -f "$1" -i RO_VPD -l --null-terminated > "$2" 2>>"$log" && [ -s "$2" ]
}

[ "$(id -u)" = 0 ] || die 'Lancer ce script avec sudo sh depuis VT2.'
for tool in crossystem device_management_client gsctool futility vpd openssl sha256sum dd; do
    command -v "$tool" >/dev/null || die "Outil manquant : $tool"
done
case "$(crossystem hwid)" in TARKIN*) ;; *) die 'Ce script est limite aux ASUS Tarkin.' ;; esac
grep -Eq '^CHROMEOS_RELEASE_BOARD="?skywalker-signed-mp-v12keys"?$' /etc/lsb-release &&
    grep -Eq '^CHROMEOS_RELEASE_VERSION="?16765\.51\.0"?$' /etc/lsb-release ||
    die 'Installer la recuperation Skywalker 152 (16765.51.0) avant de continuer.'
[ "$(crossystem cros_debug)" = 1 ] || die 'Mode developpeur requis.'

backup=/mnt/stateful_partition/tarkin-vt2
if [ ! -d "$backup" ]; then mkdir -m 700 "$backup"; fi
[ ! -L "$backup" ] && [ "$(stat -c '%u:%a' "$backup")" = '0:700' ] ||
    die 'Dossier de sauvegarde inattendu. Arret.'
lock=/run/tarkin-vt2.lock
mkdir "$lock" || die 'Un autre lancement est actif ou a ete interrompu.'
trap 'rmdir "$lock"' EXIT
trap 'exit 1' HUP INT TERM
[ ! -f "$backup/verified" ] || {
    printf '%s\n' 'Ecriture deja verifiee. Passez au test sur un Wi-Fi normal.'
    exit 0
}
[ ! -f "$backup/write-started" ] || die "Une ecriture precedente reste a verifier. Ne pas redemarrer ni relancer l ecriture. Sauvegarde : $backup/original.rom"

log=$backup/operation.log
check_install_state

sw=$(software_wp)
ccd=$(gsctool --any --ccd_info)
if [ "$sw" = enabled ] || ! printf '%s\n' "$ccd" | grep -Eq 'AllowUnverifiedRo[[:space:]]+Y[[:space:]]+Always'; then
    if ! printf '%s\n' "$ccd" | grep -Eq '^State:[[:space:]]+Opened'; then
        printf '%s\n' 'L ouverture du CCD peut redemarrer le Chromebook et effacer ses donnees locales.'
        confirm 'Ouvrir le CCD sur un appareil dont vous etes autorise a retirer la gestion ?'
        printf '%s\n' 'Appuyez brievement sur Marche/Arret a chaque invite Press PP button now!'
        gsctool --any --ccd_open
        printf '%s\n' 'Relancez ce script dans VT2 pour reprendre apres l ouverture du CCD.'
        exit 0
    fi
    confirm 'Modifier les protections du firmware pour reproduire les conditions verifiees ?'
    if ! printf '%s\n' "$ccd" | grep -Eq 'AllowUnverifiedRo[[:space:]]+Y[[:space:]]+Always'; then
        gsctool --any --ccd_info=AllowUnverifiedRo:always
    fi
    if [ "$sw" = enabled ]; then
        if [ "$(crossystem wpsw_cur)" = 1 ]; then
            printf '%s\n' 'Appuyez brievement sur Marche/Arret si Press PP button now! apparait.'
            gsctool --any --wp=disable
        fi
        [ "$(crossystem wpsw_cur)" = 0 ] || die 'Protection materielle encore active.'
        futility flash --wp-disable
    fi
fi
[ "$(software_wp)" = disabled ] || die 'Protection logicielle encore active.'
gsctool --any --ccd_info | grep -Eq 'AllowUnverifiedRo[[:space:]]+Y[[:space:]]+Always' ||
    die 'Reglage AllowUnverifiedRo non confirme.'

original=$backup/original.rom
candidate=$backup/candidate.rom
current=$backup/current.rom
key=stable_device_secret_DO_NOT_SHARE

printf '%s\n' 'Lecture du firmware et validation de la sauvegarde...'
futility read "$current" >>"$log" 2>&1 || die "Lecture impossible. Journal prive : $log"
futility gscvd "$current" >>"$log" 2>&1 || die 'Validation GSCVD de la flash actuelle en echec.'
outside_vpd "$current" "$backup/current" || die 'Taille ou lecture du firmware inattendue.'
if [ -f "$original" ]; then
    same_file "$original" "$current" || die 'La flash a change depuis la sauvegarde. Arret.'
else
    mv "$current" "$original"
fi
cp "$original" "$candidate"
openssl rand -hex 32 > "$backup/secret"
grep -Eq '^[0-9a-f]{64}$' "$backup/secret" || die 'Secret genere invalide.'
vpd -f "$candidate" -i RO_VPD -S "$key=$backup/secret" >>"$log" 2>&1 || die 'Preparation de la copie en echec.'
futility gscvd "$candidate" >>"$log" 2>&1 || die 'Validation GSCVD de la copie en echec.'
outside_vpd "$candidate" "$backup/candidate" &&
    same_file "$backup/current.prefix" "$backup/candidate.prefix" &&
    same_file "$backup/current.tail" "$backup/candidate.tail" || die 'La copie modifie des octets hors de RO_VPD.'
read_vpd "$candidate" "$backup/expected.vpd" || die 'Lecture VPD de la copie en echec.'

printf '%s\n' "Sauvegarde privee : $original" 'Conservez une copie hors du Chromebook avant de continuer. Le Powerwash efface cette sauvegarde locale.'
confirm 'La sauvegarde externe est faite et vous autorisez l ecriture du secret dans la flash ?'
check_install_state
[ "$(software_wp)" = disabled ] || die 'La protection logicielle a change.'
futility read "$current" >>"$log" 2>&1 && same_file "$original" "$current" ||
    die 'La flash a change depuis la sauvegarde. Arret.'

: > "$backup/write-started"
sync
vpd -i RO_VPD -S "$key=$backup/secret" >>"$log" 2>&1 ||
    die "Ecriture non confirmee. Ne redemarrez pas. Journal prive : $log"
futility read "$current" >>"$log" 2>&1 &&
    read_vpd "$current" "$backup/actual.vpd" &&
    same_file "$backup/expected.vpd" "$backup/actual.vpd" &&
    outside_vpd "$current" "$backup/current" &&
    same_file "$backup/current.prefix" "$backup/candidate.prefix" &&
    same_file "$backup/current.tail" "$backup/candidate.tail" &&
    futility gscvd "$current" >>"$log" 2>&1 ||
    die "Verification en echec. Ne redemarrez pas. Journal prive : $log"
: > "$backup/verified"
sync
printf '%s\n' 'Ecriture verifiee. Numero de serie conserve.' 'Redemarrez manuellement et testez la configuration personnelle sur un Wi-Fi normal, sans proxy.'
