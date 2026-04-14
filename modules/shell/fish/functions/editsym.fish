function editsym --description 'Convert symlinks to regular files for editing'
    for file in $argv
        cp "$file" "$file.tmp"
        unlink "$file"
        mv "$file.tmp" "$file"
        chmod 644 "$file"
    end
end
