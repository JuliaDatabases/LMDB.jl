using Documenter, LMDB

function main()
    ci = get(ENV, "CI", "") == "true"

    makedocs(
        sitename = "LMDB.jl",
        authors = "Art Wild, Fabian Gans, Tim Besard",
        format = Documenter.HTML(prettyurls = ci,
                                 edit_link = "master"),
        modules = [LMDB],
        checkdocs = :exports,
        pages = [
            "Home" => "index.md",
            "Usage" => [
                "man/essentials.md",
                "man/dict.md",
                "man/environments.md",
                "man/transactions.md",
                "man/databases.md",
                "man/cursors.md",
                "man/dupsort.md",
                "man/lowlevel.md",
            ],
            "API reference" => [
                "lib/dict.md",
                "lib/environments.md",
                "lib/transactions.md",
                "lib/databases.md",
                "lib/cursors.md",
                "lib/errors.md",
                "lib/lowlevel.md",
            ],
        ],
    )

    if ci
        deploydocs(
            repo = "github.com/wildart/LMDB.jl.git",
        )
    end
end

isinteractive() || main()
