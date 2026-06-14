#!/usr/bin/env python3
"""
Check AgentMail inbox for messages

Usage:
    # List recent messages
    python check_inbox.py --inbox "myagent@agentmail.to"

    # Get specific message
    python check_inbox.py --inbox "myagent@agentmail.to" --message "msg_123abc"

    # List threads
    python check_inbox.py --inbox "myagent@agentmail.to" --threads

    # Monitor for new messages (poll every N seconds)
    python check_inbox.py --inbox "myagent@agentmail.to" --monitor 30

Environment:
    AGENTMAIL_API_KEY: Your AgentMail API key
"""

import argparse
import os
import sys
import time
from datetime import datetime

try:
    from agentmail import AgentMail
except ImportError:
    print("Error: agentmail package not found. Install with: pip install agentmail")
    sys.exit(1)


def format_timestamp(ts):
    """Format a datetime or ISO string for display"""
    if isinstance(ts, str):
        try:
            ts = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        except ValueError:
            return ts
    return ts.strftime("%Y-%m-%d %H:%M:%S")


def print_message_summary(message):
    """Print a summary of a message"""
    from_addr = message.from_
    subject = message.subject or "(no subject)"
    timestamp = format_timestamp(message.timestamp)
    preview = (message.preview or "")[:100]

    print(f"📧 {message.message_id}")
    print(f"   From: {from_addr}")
    print(f"   Subject: {subject}")
    print(f"   Time: {timestamp}")
    if preview:
        print(f"   Preview: {preview}{'...' if len(preview) == 100 else ''}")
    print()


def print_thread_summary(thread):
    """Print a summary of a thread"""
    subject = thread.subject or "(no subject)"
    participants = ", ".join(thread.senders)
    count = thread.message_count
    timestamp = format_timestamp(thread.timestamp)

    print(f"🧵 {thread.thread_id}")
    print(f"   Subject: {subject}")
    print(f"   Participants: {participants}")
    print(f"   Messages: {count}")
    print(f"   Last: {timestamp}")
    print()


def main():
    parser = argparse.ArgumentParser(description="Check AgentMail inbox")
    parser.add_argument("--inbox", required=True, help="Inbox email address")
    parser.add_argument("--message", help="Get specific message by ID")
    parser.add_argument(
        "--threads", action="store_true", help="List threads instead of messages"
    )
    parser.add_argument(
        "--monitor",
        type=int,
        metavar="SECONDS",
        help="Monitor for new messages (poll interval)",
    )
    parser.add_argument(
        "--limit", type=int, default=10, help="Number of items to fetch (default: 10)"
    )

    args = parser.parse_args()

    # Get API key
    api_key = os.getenv("AGENTMAIL_API_KEY")
    if not api_key:
        print("Error: AGENTMAIL_API_KEY environment variable not set")
        sys.exit(1)

    # Initialize client
    client = AgentMail(api_key=api_key)

    if args.monitor:
        print(f"🔍 Monitoring {args.inbox} (checking every {args.monitor} seconds)")
        print("Press Ctrl+C to stop\n")

        last_message_ids = set()

        try:
            while True:
                try:
                    messages = client.inboxes.messages.list(
                        inbox_id=args.inbox, limit=args.limit
                    )

                    new_messages = []
                    current_message_ids = set()

                    for message in messages.messages:
                        msg_id = message.message_id
                        current_message_ids.add(msg_id)

                        if msg_id not in last_message_ids:
                            new_messages.append(message)

                    if new_messages:
                        print(f"🆕 Found {len(new_messages)} new message(s):")
                        for message in new_messages:
                            print_message_summary(message)

                    last_message_ids = current_message_ids

                except Exception as e:
                    print(f"❌ Error checking inbox: {e}")

                time.sleep(args.monitor)

        except KeyboardInterrupt:
            print("\n👋 Monitoring stopped")
            return

    elif args.message:
        # Get specific message
        try:
            message = client.inboxes.messages.get(
                inbox_id=args.inbox, message_id=args.message
            )

            print("📧 Message Details:")
            print(f"   ID: {message.message_id}")
            print(f"   Thread: {message.thread_id}")
            print(f"   From: {message.from_}")
            print(f"   To: {', '.join(message.to)}")
            print(f"   Subject: {message.subject or '(no subject)'}")
            print(f"   Time: {format_timestamp(message.timestamp)}")

            if message.labels:
                print(f"   Labels: {', '.join(message.labels)}")

            print("\n📝 Content:")
            if message.preview:
                print(message.preview)
            else:
                print("(No text content)")

            if message.attachments:
                print(f"\n📎 Attachments ({len(message.attachments)}):")
                for att in message.attachments:
                    print(
                        f"   • {att.filename or 'unnamed'} ({att.content_type or 'unknown type'})"
                    )

        except Exception as e:
            print(f"❌ Error getting message: {e}")
            sys.exit(1)

    elif args.threads:
        # List threads
        try:
            threads = client.inboxes.threads.list(inbox_id=args.inbox, limit=args.limit)

            if not threads.threads:
                print(f"📭 No threads found in {args.inbox}")
                return

            print(f"🧵 Threads in {args.inbox} (showing {len(threads.threads)}):\n")
            for thread in threads.threads:
                print_thread_summary(thread)

        except Exception as e:
            print(f"❌ Error listing threads: {e}")
            sys.exit(1)

    else:
        # List recent messages
        try:
            messages = client.inboxes.messages.list(
                inbox_id=args.inbox, limit=args.limit
            )

            if not messages.messages:
                print(f"📭 No messages found in {args.inbox}")
                return

            print(f"📧 Messages in {args.inbox} (showing {len(messages.messages)}):\n")
            for message in messages.messages:
                print_message_summary(message)

        except Exception as e:
            print(f"❌ Error listing messages: {e}")
            sys.exit(1)


if __name__ == "__main__":
    main()
