function row --argument n -d 'Print the Nth line from piped input'
    if test -z "$n"
        echo "Usage: ... | row <line_number>"
        return 1
    end
    sed -n "$n"'p'
end
