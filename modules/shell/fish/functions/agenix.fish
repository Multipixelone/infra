function agenix
    if test (count $argv) -eq 0
        command agenix --help
        return
    end

    if contains -- -i $argv; or contains -- --identity $argv
        command agenix $argv
        return
    end

    command agenix --identity $HOME/.ssh/agenix $argv
end
