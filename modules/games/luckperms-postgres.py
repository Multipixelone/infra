"""Provision the local role or atomically dump it, without shell commands."""
import os
import pathlib
import pwd
import subprocess
import sys
import tempfile

if sys.argv[1] == "provision":
    import psycopg
    from psycopg import sql

    password = (pathlib.Path(os.environ["CREDENTIALS_DIRECTORY"]) / "password").read_text().strip()
    # Match games-prepare's existing credential substitution contract.
    import re
    if not re.fullmatch(r"[A-Za-z0-9_-]{16,256}", password):
        raise ValueError("luckperms password must be 16–256 URL-safe characters")
    with psycopg.connect("dbname=postgres user=postgres", autocommit=True) as connection:
        connection.execute(sql.SQL("ALTER ROLE luckperms WITH LOGIN PASSWORD {}").format(sql.Literal(password)))
elif sys.argv[1] == "dump":
    directory = pathlib.Path("/var/backup/games-luckperms")
    identity = pwd.getpwnam("postgres")
    descriptor, temporary = tempfile.mkstemp(dir=directory, prefix=".dump-")
    def become_postgres():
        os.setgroups([])
        os.setgid(identity.pw_gid)
        os.setuid(identity.pw_uid)
    try:
        with os.fdopen(descriptor, "wb") as output:
            subprocess.run([sys.argv[2], "--format=custom", "--dbname=luckperms"],
                           stdout=output, check=True, preexec_fn=become_postgres)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, directory / "luckperms.dump")
    finally:
        pathlib.Path(temporary).unlink(missing_ok=True)
else:
    raise ValueError("unknown action")
