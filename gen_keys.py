#!/usr/bin/env python3
"""
gen_keys.py - Key Generator for MikroTikPatch
Generates Curve25519 (KCDSA) and Ed25519 (EdDSA) keypairs required for patching RouterOS.
"""

import os
import sys
import secrets
from toyecc import getcurvebyname, ECPrivateKey, Tools

ENV_FILE = ".env"

OFFICIAL_MIKRO_LICENSE_PUBKEY = "8e1067e4305fcdc0cfbf95c10f96e5dfe8c49aef486bd1a4e2e96c27f01e3e32"
OFFICIAL_MIKRO_NPK_SIGN_PUBKEY = "c293ced638a2a33c681fc8de98ee26c54eadc5390c2dfce197d35c83c416cf59"

def generate_keypairs():
    # 1. KCDSA on Curve25519 (for License signing and keyman patch)
    c_curve25519 = getcurvebyname('Curve25519')
    priv_int = secrets.randbelow(c_curve25519.n - 1) + 1
    priv_kcdsa = Tools.inttobytes_le(priv_int, 32).hex()
    pub_point = ECPrivateKey(priv_int, c_curve25519).pubkey.point
    pub_kcdsa = Tools.inttobytes_le(int(pub_point.x), 32).hex()

    # 2. EdDSA on Ed25519 (for NPK package signing)
    c_ed25519 = getcurvebyname('Ed25519')
    seed = secrets.token_bytes(32)
    priv_eddsa = seed.hex()
    pub_eddsa = ECPrivateKey.eddsa_decode(c_ed25519, seed).pubkey.eddsa_encode().hex()

    return {
        "CUSTOM_LICENSE_PRIVATE_KEY": priv_kcdsa,
        "CUSTOM_LICENSE_PUBLIC_KEY": pub_kcdsa,
        "CUSTOM_NPK_SIGN_PRIVATE_KEY": priv_eddsa,
        "CUSTOM_NPK_SIGN_PUBLIC_KEY": pub_eddsa,
        "MIKRO_LICENSE_PUBLIC_KEY": OFFICIAL_MIKRO_LICENSE_PUBKEY,
        "MIKRO_NPK_SIGN_PUBLIC_KEY": OFFICIAL_MIKRO_NPK_SIGN_PUBKEY,
    }

def create_env_file(env_path=ENV_FILE, overwrite=False):
    if os.path.exists(env_path) and not overwrite:
        print(f"[!] File {env_path} already exists. Use --force to regenerate.")
        return False

    keys = generate_keypairs()
    content = f"""# ==============================================================================
# MikroTikPatch Local Environment Configuration
# Generated automatically by gen_keys.py
# ==============================================================================

# --- Mandatory Cryptographic Keys ---
# Official MikroTik Public Keys (Targets for binary search & replace)
MIKRO_LICENSE_PUBLIC_KEY={keys['MIKRO_LICENSE_PUBLIC_KEY']}
MIKRO_NPK_SIGN_PUBLIC_KEY={keys['MIKRO_NPK_SIGN_PUBLIC_KEY']}

# Custom Keys (Used to replace official keys and sign custom packages/licenses)
CUSTOM_LICENSE_PRIVATE_KEY={keys['CUSTOM_LICENSE_PRIVATE_KEY']}
CUSTOM_LICENSE_PUBLIC_KEY={keys['CUSTOM_LICENSE_PUBLIC_KEY']}
CUSTOM_NPK_SIGN_PRIVATE_KEY={keys['CUSTOM_NPK_SIGN_PRIVATE_KEY']}
CUSTOM_NPK_SIGN_PUBLIC_KEY={keys['CUSTOM_NPK_SIGN_PUBLIC_KEY']}

# --- Optional Cloud & URL Replacements ---
# Leave empty if you do NOT run a custom upgrade/license server.
# If populated, patch.py will replace official URLs with custom URLs in binaries.
MIKRO_UPGRADE_URL=upgrade.mikrotik.com
CUSTOM_UPGRADE_URL=
MIKRO_LICENCE_URL=licence.mikrotik.com
CUSTOM_LICENCE_URL=
MIKRO_RENEW_URL=renew.mikrotik.com
CUSTOM_RENEW_URL=
MIKRO_CLOUD_URL=cloud.mikrotik.com
CUSTOM_CLOUD_URL=
MIKRO_CLOUD2_URL=cloud2.mikrotik.com
CUSTOM_CLOUD2_URL=
MIKRO_CLOUD_PUBLIC_KEY=
CUSTOM_CLOUD_PUBLIC_KEY=

# --- Optional Proprietary Loader Password ---
# Password for loader.7z (only if you have custom loader patch files from author)
LOADER_7Z_PASSWORD=
"""
    with open(env_path, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"[+] Successfully generated new keys in '{env_path}'")
    return True

if __name__ == "__main__":
    force = "--force" in sys.argv or "-f" in sys.argv
    target_env = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else ENV_FILE
    create_env_file(target_env, overwrite=force)
