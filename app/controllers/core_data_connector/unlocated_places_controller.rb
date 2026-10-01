module CoreDataConnector
  # The atlas's places that have no location: listed and searchable on the
  # atlas, but not on its map. A spreadsheet of buildings imports some of its
  # rows that way — descriptions ("Cockspur Island"), intersections ("Bay &
  # Bull Streets"), addresses the lookup couldn't place — and the console's
  # Places page is where the curator puts them on the map.
  #
  #   GET  /core_data/sites/:id/unlocated_places?page=&per_page=
  #        { places: [{ id, uuid, name, fields: [{ label, value }] }], total,
  #          located, bbox, address_fields, address, geocoder }
  #   POST /core_data/sites/:id/unlocated_places/lookup
  #        { place_ids: [...] (default: all of them), address: { street_field, city_field, city_value,
  #          state_field, state_value, zip_field, zip_value } }
  #        → { results: { place_id => { status, latitude, longitude, matched, address } } }
  #   POST /core_data/sites/:id/unlocated_places/locate
  #        { locations: [{ place_id, latitude, longitude }] } → { located }
  #
  # Only the places of the atlas's own place models, and only those still
  # without a location, can be placed here; they're reindexed in the
  # background once placed (ReindexRecordsJob).
  class UnlocatedPlacesController < ApplicationController
    PER_PAGE = 50
    LOOKUP_LIMIT = 1000
    LOCATE_LIMIT = 1000
    FIELD_TYPES = %w[String Text].freeze
    FIELD_MAX = 300

    def index
      site = authorized_site
      models = place_models(site)
      scope = unlocated(models)
      per_page = params[:per_page].present? ? params[:per_page].to_i.clamp(1, 200) : PER_PAGE
      page = [params[:page].to_i, 1].max
      labels = field_labels(models)

      places = scope.order(:id).offset((page - 1) * per_page).limit(per_page).includes(:place_names).to_a

      render json: {
        places: places.map { |place| place_json(place, labels) },
        total: scope.count,
        located: Place.where(project_model_id: models.map(&:id)).joins(:place_geometry).count,
        bbox: located_bbox(models),
        address_fields: labels.values.select { |field| FIELD_TYPES.include?(field.data_type) }.map(&:column_name).uniq,
        address: address_defaults(site, models),
        geocoder: DatasetImports::Geocoder.available? ? DatasetImports::Geocoder::PROVIDER : nil
      }, status: :ok
    end

    def lookup
      site = authorized_site
      models = place_models(site)
      # Given places, or (none given) every one still without a location.
      ids = if params[:place_ids].present?
              Array(params[:place_ids]).map(&:to_i).uniq.first(LOOKUP_LIMIT)
            else
              unlocated(models).order(:id).limit(LOOKUP_LIMIT).pluck(:id)
            end
      address = params.fetch(:address, {}).permit(:street_field, :city_field, :city_value, :state_field, :state_value, :zip_field, :zip_value).to_h
      uuids = field_labels(models).values.group_by(&:column_name).transform_values { |fields| fields.map(&:uuid) }

      names = {}
      addresses = unlocated(models).where(id: ids).includes(:place_names).each_with_object({}) do |place, wanted|
        names[place.id] = place.name
        parts = %w[street city state zip].map do |part|
          field = address["#{part}_field"].presence
          value = field ? Array(uuids[field]).filter_map { |uuid| place.user_defined&.dig(uuid).presence }.first : address["#{part}_value"]
          value.to_s.squish
        end
        parts[0] = place.name.to_s.squish if parts[0].blank? && place.name.to_s.match?(DatasetImports::Geocoder::NAMED_BY_ADDRESS)
        wanted[place.id] = parts if parts.first.present?
      end

      found = DatasetImports::Geocoder.locate(addresses)

      render json: {
        results: addresses.to_h do |id, parts|
          result = found[id]
          [id, {
            name: names[id],
            status: result&.status || 'not_found',
            latitude: result&.latitude,
            longitude: result&.longitude,
            matched: result&.matched,
            address: parts.compact_blank.join(', ')
          }.compact]
        end
      }, status: :ok
    rescue DatasetImports::Geocoder::Unavailable => e
      render json: { errors: [{ base: "#{e.message} Try again in a moment." }] }, status: :service_unavailable
    end

    def locate
      site = authorized_site
      models = place_models(site)
      locations = Array(params[:locations]).first(LOCATE_LIMIT).map { |l| l.permit(:place_id, :latitude, :longitude).to_h }

      points = locations.to_h do |location|
        latitude = Float(location['latitude'], exception: false)
        longitude = Float(location['longitude'], exception: false)

        unless latitude&.between?(-90, 90) && longitude&.between?(-180, 180)
          render json: { errors: [{ base: 'Each location needs a latitude (-90 to 90) and a longitude (-180 to 180).' }] }, status: :unprocessable_entity
          return
        end

        [location['place_id'].to_i, [longitude.round(7), latitude.round(7)]]
      end

      places = unlocated(models).where(id: points.keys).to_a

      ActiveRecord::Base.transaction do
        places.each do |place|
          PlaceGeometry.create!(place:, geometry_json: { 'type' => 'Point', 'coordinates' => points[place.id] }.to_json)
        end
      end

      # In the background: indexing a newly located place looks its area up
      # on GeoNames, about one place a second.
      ReindexRecordsJob.perform_later(site.project_id, Place.to_s, places.map(&:id)) if places.any?

      render json: { located: places.size }, status: :ok
    end

    private

    def authorized_site
      site = Site.find(params[:id])
      authorize site, :update?
      site
    end

    # The atlas's place models: those its searches cover, else every Place
    # model of its project (not Map Layers, whose places are map shapes).
    def place_models(site)
      ids = Array(site.config&.dig('search')).filter_map { |entry| entry.is_a?(Hash) ? entry['search_collection_id'] : nil }
      covered = SearchCollection.where(id: ids, project_id: site.project_id).flat_map(&:project_model_ids)
      models = ProjectModel.where(project_id: site.project_id, model_class: Place.to_s)
      covered.any? ? models.where(id: covered).to_a : models.where.not(name: 'Map Layers').to_a
    end

    def unlocated(models)
      Place.where(project_model_id: models.map(&:id)).where.missing(:place_geometry)
    end

    def field_labels(models)
      UserDefinedFields::UserDefinedField.where(defineable_type: ProjectModel.to_s, defineable_id: models.map(&:id)).index_by(&:uuid)
    end

    # The place's name and its short text fields (what an address or a
    # description is made of), web addresses left out.
    def place_json(place, labels)
      fields = (place.user_defined || {}).filter_map do |uuid, value|
        field = labels[uuid]
        next unless field && FIELD_TYPES.include?(field.data_type) && value.is_a?(String) && value.present?
        next if value.length > FIELD_MAX || value.match?(%r{\Ahttps?://}i)

        [field.order || 0, { label: field.column_name, value: value.squish }]
      end.sort_by(&:first).map(&:last)

      { id: place.id, uuid: place.uuid, name: place.name, fields: }
    end

    # [west, south, east, north] of the atlas's located places, for framing
    # the map the curator places the rest on.
    def located_bbox(models)
      row = PlaceGeometry.joins(:place).where(place: { project_model_id: models.map(&:id) })
                         .pick(Arel.sql('ST_XMin(ST_Extent(geometry)), ST_YMin(ST_Extent(geometry)), ST_XMax(ST_Extent(geometry)), ST_YMax(ST_Extent(geometry))'))
      row&.compact&.size == 4 ? row.map(&:to_f) : nil
    rescue ActiveRecord::StatementInvalid
      nil
    end

    # The address the last upload looked places up with, in terms of the
    # atlas's fields: a column kept as a field is that field; a value the
    # curator typed, or a column that held one value throughout, is that
    # value.
    def address_defaults(site, models)
      job = Job.where(project_id: site.project_id, job_type: Job::JOB_TYPE_IMPORT_DATASET, status: Job::JOB_STATUS_COMPLETED)
               .where("extra ? 'geocode'").where("extra->>'project_model_id' IN (?)", models.map { |m| m.id.to_s })
               .order(created_at: :desc).first
      return {} unless job

      geocode = job.extra['geocode'] || {}
      constants = job.extra['geocode_constants'] || {}
      labels = Array(job.extra['columns']).select { |c| %w[field identifier].include?(c['role']) }.to_h { |c| [c['name'], c['label'].presence || c['name']] }

      %w[street city state zip].each_with_object({}) do |part, address|
        column = geocode[part].presence

        if column && labels[column]
          address["#{part}_field"] = labels[column]
        elsif (value = geocode["#{part}_value"].presence || constants[part].presence)
          address["#{part}_value"] = value
        end
      end
    end
  end
end
