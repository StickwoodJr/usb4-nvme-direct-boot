#!/usr/bin/env python3
# ==============================================================================
# send_upstream_patch.py - Interactive LKML / Upstream Patch Dispatcher
# Prompts for SMTP credentials securely and dispatches patch to maintainers.
# ==============================================================================
import os
import sys
import smtplib
import ssl
import getpass
import argparse
from email.message import EmailMessage

SMTP_SERVER = "smtp.office365.com"
SMTP_PORT = 587
SENDER_EMAIL = "stickwood_jr@hotmail.com"
SENDER_NAME = "StickwoodJr"

RECIPIENT_TO = ["Mika Westerberg <mika.westerberg@linux.intel.com>"]
RECIPIENTS_CC = [
    "Greg Kroah-Hartman <gregkh@linuxfoundation.org>",
    "Bjorn Helgaas <bhelgaas@google.com>",
    "Sanath S <sanath.s@amd.com>",
    "linux-usb@vger.kernel.org",
    "linux-kernel@vger.kernel.org",
    "linux-pci@vger.kernel.org",
    "stable@vger.kernel.org",
]

SUBJECT = "[PATCH] thunderbolt: Preserve pre-boot PCIe tunnels for active storage devices"

def load_patch_body():
    candidates = [
        os.path.expanduser("~/.gemini/antigravity/brain/feb51ce4-1418-485c-9496-a5686f209053/scratch/usb4-nvme-direct-boot/patches/0001-thunderbolt-preserve-pre-boot-pcie-tunnels.patch"),
        os.path.join(os.path.dirname(__file__), "patches/0001-thunderbolt-preserve-pre-boot-pcie-tunnels.patch"),
        os.path.join(os.path.dirname(__file__), "0001-thunderbolt-preserve-pre-boot-pcie-tunnels.patch")
    ]
    for c in candidates:
        if os.path.isfile(c):
            with open(c, "r", encoding="utf-8") as f:
                lines = f.readlines()
            body_start = 0
            for i, line in enumerate(lines):
                if line.startswith("Subject:"):
                    body_start = i + 1
                    break
            while body_start < len(lines) and lines[body_start].strip() == "":
                body_start += 1
            return "".join(lines[body_start:])
    
    for c in candidates:
        if os.path.isfile(c):
            with open(c, "r", encoding="utf-8") as f:
                return f.read()

    raise FileNotFoundError("Could not locate 0001-thunderbolt-preserve-pre-boot-pcie-tunnels.patch")

def main():
    parser = argparse.ArgumentParser(description="Send USB4 Direct-Boot patch to Linux Kernel maintainers via SMTP.")
    parser.add_argument("--dry-run", action="store_true", help="Authenticate with SMTP server and verify headers without sending.")
    args = parser.parse_args()

    print("======================================================================")
    print(" Linux Kernel Upstream Patch Dispatcher")
    print(" Target Subsystem : drivers/thunderbolt/")
    print("======================================================================")
    print(f"From    : {SENDER_NAME} <{SENDER_EMAIL}>")
    print(f"To      : {', '.join(RECIPIENT_TO)}")
    print(f"Cc      : {', '.join(RECIPIENTS_CC)}")
    print(f"Subject : {SUBJECT}")
    print(f"Server  : {SMTP_SERVER}:{SMTP_PORT} (STARTTLS)")
    print("----------------------------------------------------------------------")

    try:
        patch_body = load_patch_body()
    except Exception as e:
        print(f"ERROR: Failed to load patch: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"\nPlease enter your Microsoft Account password (or App Password) for {SENDER_EMAIL}.")
    password = getpass.getpass("Password: ")

    if not password:
        print("ERROR: Password cannot be empty.", file=sys.stderr)
        sys.exit(1)

    msg = EmailMessage()
    msg["From"] = f"{SENDER_NAME} <{SENDER_EMAIL}>"
    msg["To"] = ", ".join(RECIPIENT_TO)
    msg["Cc"] = ", ".join(RECIPIENTS_CC)
    msg["Subject"] = SUBJECT
    msg.set_content(patch_body, cte="8bit")

    all_recipients = [r.split("<")[-1].rstrip(">") for r in RECIPIENT_TO + RECIPIENTS_CC]

    if not args.dry_run:
        confirm = input("\nReady to dispatch patch to LKML and maintainers? [y/N]: ").strip().lower()
        if confirm != "y":
            print("Submission aborted by user.")
            sys.exit(0)

    print(f"\nConnecting to {SMTP_SERVER}:{SMTP_PORT}...")
    context = ssl.create_default_context()

    try:
        with smtplib.SMTP(SMTP_SERVER, SMTP_PORT, timeout=20) as server:
            server.ehlo()
            server.starttls(context=context)
            server.ehlo()
            print("Authenticating credentials...")
            server.login(SENDER_EMAIL, password)
            print("  [OK] Authentication successful!")

            if args.dry_run:
                print("  [DRY-RUN] Authentication verified. Email was NOT sent.")
                return

            print("Transmitting patch email to maintainers...")
            server.send_message(msg, from_addr=SENDER_EMAIL, to_addrs=all_recipients)
            print("  [SUCCESS] Patch email sent successfully!")
            print("The patch is now in transit to linux-usb@vger.kernel.org and maintainers.")
    except smtplib.SMTPAuthenticationError as e:
        print(f"\n[FAIL] Authentication failed: {e}", file=sys.stderr)
        print("Note: If you have 2-Factor Authentication enabled on your Microsoft Account, you must use an App Password.", file=sys.stderr)
        print("Generate one at: https://account.live.com/proofs/AppPassword", file=sys.stderr)
        sys.exit(2)
    except Exception as e:
        print(f"\n[FAIL] SMTP transmission error: {e}", file=sys.stderr)
        sys.exit(3)

if __name__ == "__main__":
    main()
