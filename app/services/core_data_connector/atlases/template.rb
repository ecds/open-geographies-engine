module CoreDataConnector
  module Atlases
    # Starter ProjectModel sets for wizard-created atlases. Every template
    # includes a Place model (the wizard's search collection and authority
    # imports require one); 'atlas' mirrors the full atlas pattern and is
    # expected to be pared down per project after creation.
    class Template
      TEMPLATES = {
        'places' => [
          { name: 'Places', model_class: 'CoreDataConnector::Place' }
        ],
        'atlas' => [
          { name: 'Places', model_class: 'CoreDataConnector::Place' },
          { name: 'People', model_class: 'CoreDataConnector::Person' },
          { name: 'Media', model_class: 'CoreDataConnector::MediaContent' },
          { name: 'Topics', model_class: 'CoreDataConnector::Taxonomy' }
        ]
      }.freeze

      def self.valid?(key)
        TEMPLATES.key?(key.to_s)
      end

      # Creates the template's models in order; returns the created records.
      def self.create_models!(project, key)
        TEMPLATES.fetch(key.to_s).map.with_index do |definition, index|
          ProjectModel.create!(project:, order: index, **definition)
        end
      end
    end
  end
end
