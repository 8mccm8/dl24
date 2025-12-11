#!/bin/bash

BT_MAC_FILE="bt_mac"
RFCOMM_CHANNEL=1  # Canal RFCOMM par défaut

# Fonction pour lire une réponse utilisateur (forcée depuis /dev/tty)
ask_user() {
    local question=$1
    local default=$2
    local answer

    read -p "$question [$default] " -r answer < /dev/tty
    echo "${answer:-$default}"
}

# Vérifie si un appareil est appairé
check_paired() {
    local mac=$1
    local name=$2
    if bluetoothctl info "$mac" 2>/dev/null | grep -q "Paired: yes"; then
        echo "✅ $name ($mac) est appairé."
        return 0
    else
        echo "❌ $name ($mac) n'est PAS appairé."
        return 1
    fi
}

# Vérifie si un appareil est mappé sur /dev/rfcommX
check_rfcomm() {
    local mac=$1
    local name=$2
    local rfcomm_dev

    rfcomm_dev=$(rfcomm -a 2>/dev/null | grep -i "$mac" | awk '{print $1}')

    if [ -n "$rfcomm_dev" ]; then
        echo "✅ $name ($mac) est mappé sur $rfcomm_dev."
        return 0
    else
        echo "❌ $name ($mac) n'est PAS mappé sur un périphérique /dev/rfcommX."
        return 1
    fi
}

# Scanne et trouve un appareil par son nom
scan_and_find_device() {
    local target_name=$1
    local target_mac=$2
    local mac_found=false

    # Active lastpipe pour éviter le sous-shell dans le pipeline
    shopt -s lastpipe
    echo "🔍 Lancement du scan Bluetooth (20s)..."
    bluetoothctl --timeout 20 scan on  | while read -r line; do
        if [[ "$line" =~ \[.*NEW.*\][[:space:]]+Device[[:space:]]+($target_mac)[[:space:]]+($target_name)[[:space:]]*$ ]]; then 
            local current_mac="${BASH_REMATCH[1]}"
            local current_name="${BASH_REMATCH[2]}"
	    echo "current MAC :$current_mac"
	    echo "current NAME:$current_name"
            mac_found=true
	    break
        fi
    done

    if $mac_found; then
        echo "✅ Appareil trouvé : $target_name ($current_mac).$target_mac"
        return 0
    else
        echo "❌ Aucun appareil correspondant à '$target_name' trouvé."
        return 1
    fi
}

# Appaire un appareil via bluetoothctl
pair_device() {
    local mac=$1
    local name=$2

    echo -e "\n🔍 Tentative d'appairage de $name ($mac)=======================================..."

    # Active l'agent Bluetooth
    #bluetoothctl agent on 2>/dev/null
    #bluetoothctl default-agent 2>/dev/null

    # Appaire l'appareil (timeout 30s)
    if timeout 30 bluetoothctl pair "$mac" 2>/dev/null | grep -q "Pairing successful"; then
        echo "✅ Appairage réussi pour $name ($mac)."
        return 0
    else
        echo "❌ Échec de l'appairage pour $name ($mac)."
        return 1
    fi
}

# Mappe un appareil sur /dev/rfcommX
map_rfcomm() {
    local mac=$1
    local name=$2
    local rfcomm_dev="/dev/rfcomm$RFCOMM_CHANNEL"

    echo -e "\n🔌 Tentative de mappage de $name ($mac) sur $rfcomm_dev..."

    # Libère le canal RFCOMM si déjà utilisé
    sudo rfcomm release "$rfcomm_dev" 2>/dev/null

    # Mappe l'appareil
    if sudo rfcomm bind "$rfcomm_dev" "$mac"; then
        echo "✅ Mappage réussi : $name ($mac) → $rfcomm_dev."
        return 0
    else
        echo "❌ Échec du mappage pour $name ($mac)."
        return 1
    fi
}

# Vérifie et corrige les appareils
check_and_fix_devices() {
    local all_ok=true

    while IFS=';' read -r mac name; do
        # Ignore les lignes vides
        [ -z "$mac" ] && continue

        echo -e "\n=== Vérification de $name ($mac) ==="

        # Vérifie l'appairage
        if ! check_paired "$mac" "$name"; then
            local answer=$(ask_user "❓ $name n'est pas appairé. Voulez-vous lancer un scan pour le trouver ? (o/n)" "n")
            if [[ "$answer" == "o" || "$answer" == "O" ]]; then
                local found_mac=$(scan_and_find_device "$name" "$mac")
                if [ $? -eq 0 ]; then
                    if ! pair_device "$mac" "$name"; then
                        all_ok=false
                        continue
                    fi
                else
                    all_ok=false
                    continue
                fi
            else
                all_ok=false
                continue
            fi
        fi

        # Vérifie le mappage RFCOMM
        if ! check_rfcomm "$mac" "$name"; then
            local answer=$(ask_user "❓ $name n'est pas mappé sur /dev/rfcomm$RFCOMM_CHANNEL. Voulez-vous le mapper ? (o/n)" "n")
            if [[ "$answer" == "o" || "$answer" == "O" ]]; then
                if ! map_rfcomm "$mac" "$name"; then
                    all_ok=false
                fi
            else
                all_ok=false
            fi
        fi
    done < "$BT_MAC_FILE"

    if $all_ok; then
        echo -e "\n=== Résumé ==="
        echo "✅ Tous les appareils sont appairés et mappés."
    else
        echo -e "\n=== Résumé ==="
        echo "❌ Certains appareils nécessitent une attention manuelle."
        exit 1
    fi
}

# Vérifie les prérequis
if ! command -v bluetoothctl &> /dev/null; then
    echo "Erreur : bluetoothctl n'est pas installé."
    exit 1
fi

if ! command -v rfcomm &> /dev/null; then
    echo "Erreur : rfcomm n'est pas installé (paquet bluez-utils ou bluez)."
    exit 1
fi

# Vérifie si le fichier bt_mac existe
if [ ! -f "$BT_MAC_FILE" ]; then
    echo "Erreur : Le fichier $BT_MAC_FILE n'existe pas."
    exit 1
fi

# Exécute la vérification et correction
check_and_fix_devices

