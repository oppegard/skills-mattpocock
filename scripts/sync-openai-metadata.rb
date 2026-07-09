#!/usr/bin/env ruby
# frozen_string_literal: true

# Create a Ruby 2.6.10 script in scripts/ to  address https://github.com/mattpocock/skills/issues/163.
# This project is a *fork* of https://github.com/mattpocock/skills, so I need something that is
#  easy to run and update as I sync upstream changes over time. It should:
#  1) have a `generate` command that creates or updates `agents/openai.yaml`.
#    The file should always exist for each skill – the only thing that changes is whether
#    `allow_implicit_invocation` is true or false.
#  2) have a `report` command that audits every skill in the repo and audits whether an `agents/openai.yaml` exists and if it has the correct contents
#  3) have a `delete` command that deletes every `agents/openai.yaml` file

require "fileutils"
require "find"
require "pathname"
require "yaml"

$stdout.sync = true
$stderr.sync = true

REPO = Pathname.new(__dir__).join("..").expand_path
SKILLS_ROOT = REPO.join("skills")
METADATA_RELATIVE_PATH = Pathname.new("agents/openai.yaml")
VALID_COMMANDS = %w[delete generate report].freeze

def usage
  warn <<~USAGE
    Usage: scripts/sync-openai-metadata.rb <command>

    Commands:
      generate  Create or update every skill's agents/openai.yaml file.
      report    Audit every skill's agents/openai.yaml file without changes.
      delete    Delete every agents/openai.yaml file under skills/.
  USAGE
end

def relative_path(path)
  Pathname.new(path).relative_path_from(REPO).to_s
end

def skill_files
  files = []

  Find.find(SKILLS_ROOT.to_s) do |path|
    if File.directory?(path)
      Find.prune if File.basename(path) == "node_modules"
      next
    end

    files << Pathname.new(path) if File.basename(path) == "SKILL.md"
  end

  files.sort_by { |path| relative_path(path) }
end

def metadata_files
  files = []

  Find.find(SKILLS_ROOT.to_s) do |path|
    if File.directory?(path)
      Find.prune if File.basename(path) == "node_modules"
      next
    end

    files << Pathname.new(path) if path.end_with?(METADATA_RELATIVE_PATH.to_s)
  end

  files.sort_by { |path| relative_path(path) }
end

def metadata_path_for(skill_md)
  skill_md.dirname.join(METADATA_RELATIVE_PATH)
end

def frontmatter(skill_md)
  lines = File.readlines(skill_md, chomp: true)
  return nil unless lines.first == "---"

  closing_index = lines[1..-1].index("---")
  return nil unless closing_index

  lines[1, closing_index].join("\n")
end

def metadata_for(skill_md)
  yaml = frontmatter(skill_md)
  data = yaml ? YAML.safe_load(yaml, permitted_classes: [], permitted_symbols: [], aliases: false, filename: skill_md.to_s) : {}
  data = {} unless data.is_a?(Hash)

  {
    allow_implicit_invocation: data["disable-model-invocation"] != true
  }
rescue Psych::Exception => error
  warn "error: #{relative_path(skill_md)} has invalid frontmatter: #{error.message}"
  exit 2
end

def expected_content_for(skill_md)
  allow_implicit_invocation = metadata_for(skill_md).fetch(:allow_implicit_invocation)

  <<~YAML
    policy:
      allow_implicit_invocation: #{allow_implicit_invocation}
  YAML
end

def write_expected_metadata(skill_md)
  metadata_file = metadata_path_for(skill_md)
  expected_content = expected_content_for(skill_md)

  FileUtils.mkdir_p(metadata_file.dirname)
  if File.file?(metadata_file) && File.binread(metadata_file) == expected_content
    puts "ok #{relative_path(metadata_file)}"
  else
    action = File.exist?(metadata_file) ? "updated" : "created"
    File.binwrite(metadata_file, expected_content)
    puts "#{action} #{relative_path(metadata_file)}"
  end
end

def report_metadata(skill_md)
  metadata_file = metadata_path_for(skill_md)
  expected_content = expected_content_for(skill_md)

  unless File.file?(metadata_file)
    puts "missing #{relative_path(metadata_file)}"
    return 1
  end

  if File.binread(metadata_file) == expected_content
    status = YAML.safe_load(expected_content).fetch('policy').fetch('allow_implicit_invocation')? "allowed" : "disallowed"
    puts "ok/#{status} #{relative_path(metadata_file)}"
    return 0
  end

  puts "stale #{relative_path(metadata_file)}"
  1
end

def remove_empty_agents_dir(metadata_file)
  agents_dir = metadata_file.dirname
  Dir.rmdir(agents_dir)
rescue Errno::ENOENT, Errno::ENOTEMPTY
  nil
end

def delete_metadata(metadata_file)
  if File.file?(metadata_file)
    FileUtils.rm_f(metadata_file)
    remove_empty_agents_dir(metadata_file)
    puts "deleted #{relative_path(metadata_file)}"
  else
    puts "skipped #{relative_path(metadata_file)}"
  end
end

def report_orphaned_metadata(known_metadata_paths)
  status = 0

  metadata_files.each do |metadata_file|
    next if known_metadata_paths.include?(metadata_file)

    puts "orphan #{relative_path(metadata_file)}"
    status = 1
  end

  status
end

def delete_orphaned_metadata(known_metadata_paths)
  metadata_files.each do |metadata_file|
    next if known_metadata_paths.include?(metadata_file)

    delete_metadata(metadata_file)
  end
end

def main(command)
  unless VALID_COMMANDS.include?(command)
    usage
    exit 2
  end

  case command
  when "generate"
    skills = skill_files
    known_metadata_paths = skills.map { |skill_md| metadata_path_for(skill_md) }

    skills.each { |skill_md| write_expected_metadata(skill_md) }
    delete_orphaned_metadata(known_metadata_paths)
  when "report"
    status = 0
    skills = skill_files

    skills.each do |skill_md|
      status = 1 if report_metadata(skill_md) != 0
    end

    status = 1 if report_orphaned_metadata(skills.map { |skill_md| metadata_path_for(skill_md) }) != 0
    exit status
  when "delete"
    metadata_files.each { |metadata_file| delete_metadata(metadata_file) }
  end
end

main(ARGV.fetch(0, nil))
