# frozen_string_literal: true

class ScriptsController < ApplicationController
  def version
    script_name = params[:name]
    unless script_name.to_s.match?(/\A[a-z0-9-]+\z/i)
      render json: { error: "Script not found" }, status: :not_found
      return
    end

    changelog_path = Rails.root.join("public", "scripts", "#{script_name}.changelog.json")

    unless File.exist?(changelog_path)
      render json: { error: "Script not found" }, status: :not_found
      return
    end

    cache_key = "scripts/#{script_name}/version/#{File.mtime(changelog_path).to_i}"

    changelog_data = Rails.cache.fetch(cache_key, expires_in: 1.day) do
      JSON.parse(File.read(changelog_path))
    end

    render json: changelog_data
  end
end
