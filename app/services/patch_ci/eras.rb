module PatchCi
  # eras.yml, read from Rails. Until now only postgres-ci's
  # .github/workflows/build-era-images.yml read it, and the app knew majors only
  # through EraDetector::SUPPORTED_MAJORS - so a major-to-family mapping in Ruby
  # would have been a second copy free to drift from the image build.
  #
  # The file is a copy of postgres-ci's, see its header: reading it out of a
  # sibling checkout worked on my machine only, and left the app, its specs and
  # the image without the mapping everywhere else.
  class Eras
    PATH = Rails.root.join("config/patch_ci/eras.yml")

    Family = Struct.new(:name, :majors, :enabled, keyword_init: true)

    class << self
      def families
        @families ||= load_families
      end

      def family_for(major)
        families.find { |family| family.majors.include?(major.to_i) }
      end

      def name_for(major)
        family_for(major)&.name
      end

      def enabled?(major)
        family_for(major)&.enabled || false
      end

      # class-level memo, so specs and console reloads need a way out
      def reset!
        @families = nil
      end

      private

      def load_families
        YAML.safe_load_file(PATH).fetch("families").map do |name, config|
          Family.new(name: name,
                     majors: config.fetch("majors").keys.map(&:to_i).sort.freeze,
                     enabled: config["enabled"] == true).freeze
        end.freeze
      end
    end
  end
end
