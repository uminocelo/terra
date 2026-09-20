# Builds the Terra guides with Manto.

# Run it through `scripts/build_guides.sh`, which changes into Manto's own
# checkout first: Manto resolves its project, dependencies and lock file from
# the current directory, so the build has to happen there.
#
# The guides in `guides/` stay plain Markdown, because the same files are
# ExDoc extras and ExDoc renders front matter literally. Manto needs front
# matter for titles and tags, so the script below stages a copy of the vault
# under Manto's gitignored `tmp/`, generating the front matter from each
# page's first heading. Terra's `manto.json` holds the site settings and theme,
# and the output goes to Terra's `dist/`.

defmodule TerraDocs.Build do
  @moduledoc false

  @heading ~r/^#\s+(.+?)\s*$/m
  @tags ["guides", "terra"]

  # Stage every page from `source_dir` into `vault_dir`, adding the front
  # matter Manto reads for titles and tags.
  def stage_vault(source_dir, vault_dir) do
    File.rm_rf!(vault_dir)

    for source <- Path.wildcard(Path.join(source_dir, "**/*.md")) do
      relative = Path.relative_to(source, source_dir)
      target = Path.join(vault_dir, relative)

      File.mkdir_p!(Path.dirname(target))
      File.write!(target, with_front_matter(File.read!(source), relative))
    end

    vault_dir
  end

  defp with_front_matter(markdown, relative_path) do
    if String.starts_with?(markdown, "---\n") do
      markdown
    else
      "---\ntitle: #{title(markdown, relative_path)}\ntags: #{Enum.join(@tags, ", ")}\n---\n\n" <>
        markdown
    end
  end

  # The page title is its first heading, falling back to the file name.
  defp title(markdown, relative_path) do
    case Regex.run(@heading, markdown) do
      [_, heading] -> heading |> String.trim_trailing("#") |> String.trim()
      nil -> relative_path |> Path.basename(".md") |> String.replace("_", " ")
    end
  end
end

terra_dir = System.fetch_env!("TERRA_DIR")
output_dir = System.fetch_env!("TERRA_OUTPUT")

vault_dir =
  TerraDocs.Build.stage_vault(
    Path.join(terra_dir, "guides"),
    Path.join([File.cwd!(), "tmp", "terra-vault"])
  )

config =
  terra_dir
  |> Path.join("manto.json")
  |> File.read!()
  |> Jason.decode!()
  |> Map.put("vault_path", vault_dir)

config_path = Path.join([File.cwd!(), "tmp", "terra-site.json"])
File.write!(config_path, Jason.encode!(config, pretty: true) <> "\n")

Application.put_env(:manto, :config_path, config_path)

theme_args =
  case System.get_env("TERRA_THEME") do
    nil -> []
    "" -> []
    theme -> ["--theme", theme]
  end

Mix.Tasks.Manto.Build.run(["--output", output_dir] ++ theme_args)