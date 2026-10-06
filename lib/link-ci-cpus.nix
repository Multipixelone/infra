''
  # Identify whole physical cores, including every online SMT sibling. CPU IDs
  # and sibling spacing can change with firmware or the replacement processor.
  LC_ALL=C lscpu --parse=CPU,CORE,SOCKET,ONLINE | awk -F, '
    /^#/ { next }
    NF != 4 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[YN]$/ {
      invalid = 1; next
    }
    seen[$1]++ { invalid = 1; next }
    {
      key = sprintf("%010d:%010d", $3, $2)
      total[key]++
      if ($4 == "Y") {
        online[key]++
        cpus[key] = cpus[key] (cpus[key] == "" ? "" : ",") $1
      }
    }
    END {
      for (key in total)
        if (online[key] == total[key]) eligible[key] = cpus[key]
      count = asorti(eligible, keys)
      if (invalid || count < 2) {
        print "Cannot select two complete online CI cores" > "/dev/stderr"
        exit 1
      }
      print eligible[keys[count-1]] "," eligible[keys[count]]
    }
  '
''
