# frozen_string_literal: true

class HashtagAutocompleteService
  HASHTAGS_PER_REQUEST = 20
  SEARCH_MAX_LIMIT = 50

  def self.search_conditions
    @search_conditions ||= Enum.new(contains: 0, starts_with: 1)
  end

  attr_reader :guardian
  cattr_reader :data_sources, :contexts

  def self.register_data_source(type, klass)
    @@data_sources[type] = klass
  end

  def self.clear_registered
    @@data_sources = {}
    @@contexts = {}

    register_data_source("category", CategoryHashtagDataSource)
    register_data_source("tag", TagHashtagDataSource)

    register_type_in_context("category", "topic-composer", 100)
    register_type_in_context("tag", "topic-composer", 50)
  end

  def self.register_type_in_context(type, context, priority)
    @@contexts[context] = @@contexts[context] || {}
    @@contexts[context][type] = priority
  end

  def self.data_source_icons
    @@data_sources.values.map(&:icon)
  end

  def self.ordered_types_for_context(context)
    return [] if @@contexts[context].blank?
    @@contexts[context].sort_by { |param, priority| priority }.reverse.map(&:first)
  end

  def self.contexts_with_ordered_types
    Hash[@@contexts.keys.map { |context| [context, ordered_types_for_context(context)] }]
  end

  clear_registered

  class HashtagItem
    # The text to display in the UI autocomplete menu for the item.
    attr_accessor :text

    # The description text to display in the UI autocomplete menu on hover.
    # This will be things like e.g. category description.
    attr_accessor :description

    # Canonical slug for the item. Different from the ref, which can
    # have the type as a suffix to distinguish between conflicts.
    attr_accessor :slug

    # The icon to display in the UI autocomplete menu for the item.
    attr_accessor :icon

    # Distinguishes between different entities e.g. tag, category.
    attr_accessor :type

    # Inserted into the textbox when an autocomplete item is selected,
    # and must be unique so it can be used for lookups via the #lookup
    # method above.
    attr_accessor :ref

    # The relative URL for the resource that is represented by the autocomplete
    # item, used for the cooked hashtags, e.g. /c/2/staff
    attr_accessor :relative_url

    def initialize(params = {})
      @relative_url = params[:relative_url]
      @text = params[:text]
      @description = params[:description]
      @icon = params[:icon]
      @type = params[:type]
      @ref = params[:ref]
      @slug = params[:slug]
    end

    def to_h
      {
        relative_url: self.relative_url,
        text: self.text,
        description: self.description,
        icon: self.icon,
        type: self.type,
        ref: self.ref,
        slug: self.slug,
      }
    end
  end

  def initialize(guardian)
    @guardian = guardian
  end

  ##
  # Finds resources of the provided types by their exact slugs, unlike
  # search which can search partial names, slugs, etc. Used for cooking
  # fully formed #hashtags in the markdown pipeline. The @guardian handles
  # permissions around which results should be returned here.
  #
  # @param {Array} slugs The fully formed slugs to look up, which can have
  #                      ::type suffixes attached as well (e.g. ::category),
  #                      and in the case of categories can have parent:child
  #                      relationships.
  # @param {Array} types_in_priority_order The resource types we are looking up
  #                                        and the priority order in which we should
  #                                        match them if they do not have type suffixes.
  # @returns {Hash} A hash with the types as keys and an array of HashtagItem that
  #                 matches the provided slugs.
  def lookup(slugs, types_in_priority_order)
    raise Discourse::InvalidParameters.new(:slugs) if !slugs.is_a?(Array)
    raise Discourse::InvalidParameters.new(:order) if !types_in_priority_order.is_a?(Array)

    types_in_priority_order =
      types_in_priority_order.select { |type| @@data_sources.keys.include?(type) }
    lookup_results = Hash[types_in_priority_order.collect { |type| [type.to_sym, []] }]
    limited_slugs = slugs[0..HashtagAutocompleteService::HASHTAGS_PER_REQUEST]

    slugs_without_suffixes =
      limited_slugs.reject do |slug|
        @@data_sources.keys.any? { |type| slug.ends_with?("::#{type}") }
      end
    slugs_with_suffixes = (limited_slugs - slugs_without_suffixes)

    # For all the slugs without a type suffix, we need to lookup in order, falling
    # back to the next type if no results are returned for a slug for the current
    # type. This way slugs without suffix make sense in context, e.g. in the topic
    # composer we want a slug without a suffix to be a category first, tag second.
    if slugs_without_suffixes.any?
      types_in_priority_order.each do |type|
        # We do not want to continue fallback if there are conflicting slugs where
        # one has a type and one does not, this may result in duplication. An
        # example:
        #
        # A category with slug `management` is not found because of permissions
        # and we also have a slug with suffix in the form of `management::tag`.
        # There is a tag that exists with the `management` slug. The tag should
        # not be found here but rather in the next lookup since it's got a more
        # specific lookup with the type.
        slugs_to_lookup =
          slugs_without_suffixes.reject { |slug| slugs_with_suffixes.include?("#{slug}::#{type}") }
        found_from_slugs = execute_lookup!(lookup_results, type, guardian, slugs_to_lookup)

        slugs_without_suffixes = slugs_without_suffixes - found_from_slugs.map(&:ref)
        break if slugs_without_suffixes.empty?
      end
    end

    # We then look up the remaining slugs based on their type suffix, stripping out
    # the type suffix first since it will not match the actual slug.
    if slugs_with_suffixes.any?
      types_in_priority_order.each do |type|
        slugs_for_type =
          slugs_with_suffixes
            .select { |slug| slug.ends_with?("::#{type}") }
            .map { |slug| slug.gsub("::#{type}", "") }
        next if slugs_for_type.empty?
        execute_lookup!(lookup_results, type, guardian, slugs_for_type)

        # Make sure the refs are the same going out as they were going in.
        lookup_results[type.to_sym].each do |item|
          item.ref = "#{item.ref}::#{type}" if slugs_with_suffixes.include?("#{item.ref}::#{type}")
        end
      end
    end

    lookup_results
  end

  ##
  # Searches registered hashtag data sources using the provided term (data
  # sources determine what is actually searched) and prioritises the results
  # based on types_in_priority_order and the limit. For example, if 5 categories
  # were returned for the term and the limit was 5, we would not even bother
  # searching tags. The @guardian handles permissions around which results should
  # be returned here.
  #
  # Items which have a slug that exactly matches the search term via lookup will be found
  # first and floated to the top of the results, and still be ordered by type.
  #
  # @param {String} term Search term, from the UI generally where the user is typing #has...
  # @param {Array} types_in_priority_order The resource types we are searching for
  #                                        and the priority order in which we should
  #                                        return them.
  # @param {Integer} limit The maximum number of search results to return, we don't
  #                        bother searching subsequent types if the first types in
  #                        the array already reach the limit.
  # @returns {Array} The results as HashtagItems
  def search(
    term,
    types_in_priority_order,
    limit: SiteSetting.experimental_hashtag_search_result_limit
  )
    raise Discourse::InvalidParameters.new(:order) if !types_in_priority_order.is_a?(Array)
    limit = [limit, SEARCH_MAX_LIMIT].min

    return search_without_term(types_in_priority_order, limit) if term.blank?

    limited_results = []
    top_ranked_type = nil
    term = term.downcase
    types_in_priority_order =
      types_in_priority_order.select { |type| @@data_sources.keys.include?(type) }

    # Float exact matches by slug to the top of the list, any of these will be excluded
    # from further results.
    types_in_priority_order.each do |type|
      search_results = execute_lookup!(nil, type, guardian, [term])
      limited_results.concat(search_results) if search_results
      break if limited_results.length >= limit
    end

    # Next priority are slugs which start with the search term.
    if limited_results.length < limit
      types_in_priority_order.each do |type|
        limited_results =
          search_using_condition(
            limited_results,
            term,
            type,
            limit,
            HashtagAutocompleteService.search_conditions[:starts_with],
          )
        top_ranked_type = type if top_ranked_type.nil?
        break if limited_results.length >= limit
      end
    end

    # Search the data source for each type, validate and sort results,
    # and break off from searching more data sources if we reach our limit
    if limited_results.length < limit
      types_in_priority_order.each do |type|
        limited_results =
          search_using_condition(
            limited_results,
            term,
            type,
            limit,
            HashtagAutocompleteService.search_conditions[:contains],
          )
        top_ranked_type = type if top_ranked_type.nil?
        break if limited_results.length >= limit
      end
    end

    # Any items that are _not_ the top-ranked type (which could possibly not be
    # the same as the first item in the types_in_priority_order if there was
    # no data for that type) that have conflicting slugs with other items for
    # other types need to have a ::type suffix added to their ref.
    #
    # This will be used for the lookup method above if one of these items is
    # chosen in the UI, otherwise there is no way to determine whether a hashtag is
    # for a category or a tag etc.
    #
    # For example, if there is a category with the slug #general and a tag
    # with the slug #general, then the tag will have its ref changed to #general::tag
    append_types_to_conflicts(limited_results, top_ranked_type, limit)
  end

  # TODO (martin) Remove this once plugins are not relying on the old lookup
  # behavior via HashtagsController when enable_experimental_hashtag_autocomplete is removed
  def lookup_old(slugs)
    raise Discourse::InvalidParameters.new(:slugs) if !slugs.is_a?(Array)

    all_slugs = []
    tag_slugs = []

    slugs[0..HashtagAutocompleteService::HASHTAGS_PER_REQUEST].each do |slug|
      if slug.end_with?(PrettyText::Helpers::TAG_HASHTAG_POSTFIX)
        tag_slugs << slug.chomp(PrettyText::Helpers::TAG_HASHTAG_POSTFIX)
      else
        all_slugs << slug
      end
    end

    # Try to resolve hashtags as categories first
    category_slugs_and_ids =
      all_slugs.map { |slug| [slug, Category.query_from_hashtag_slug(slug)&.id] }.to_h
    category_ids_and_urls =
      Category
        .secured(guardian)
        .select(:id, :slug, :parent_category_id) # fields required for generating category URL
        .where(id: category_slugs_and_ids.values)
        .map { |c| [c.id, c.url] }
        .to_h
    categories_hashtags = {}
    category_slugs_and_ids.each do |slug, id|
      if category_url = category_ids_and_urls[id]
        categories_hashtags[slug] = category_url
      end
    end

    # Resolve remaining hashtags as tags
    tag_hashtags = {}
    if SiteSetting.tagging_enabled
      tag_slugs += (all_slugs - categories_hashtags.keys)
      DiscourseTagging
        .filter_visible(Tag.where_name(tag_slugs), guardian)
        .each { |tag| tag_hashtags[tag.name] = tag.full_url }
    end

    { categories: categories_hashtags, tags: tag_hashtags }
  end

  private

  def search_using_condition(limited_results, term, type, limit, condition)
    search_results =
      search_for_type(type, guardian, term, limit - limited_results.length, condition)
    return limited_results if search_results.empty?

    search_results =
      @@data_sources[type].search_sort(
        search_results.reject do |item|
          limited_results.any? { |exact| exact.type == type && exact.slug === item.slug }
        end,
        term,
      )

    limited_results.concat(search_results)
  end

  def search_without_term(types_in_priority_order, limit)
    split_limit = (limit.to_f / types_in_priority_order.length.to_f).ceil
    limited_results = []

    types_in_priority_order.each do |type|
      search_results =
        filter_valid_data_items(@@data_sources[type].search_without_term(guardian, split_limit))
      next if search_results.empty?

      # This is purposefully unsorted as search_without_term should sort
      # in its own way.
      limited_results.concat(set_types(set_refs(search_results), type))
    end

    limited_results.take(limit)
  end

  # Sometimes a specific ref is required, e.g. for categories that have
  # a parent their ref will be parent_slug:child_slug, though most of the
  # time it will be the same as the slug. The ref can then be used for
  # lookup in the UI.
  def set_refs(hashtag_items)
    hashtag_items.each { |item| item.ref ||= item.slug }
  end

  def set_types(hashtag_items, type)
    hashtag_items.each { |item| item.type = type }
  end

  def filter_valid_data_items(items)
    items.select { |item| item.kind_of?(HashtagItem) && item.slug.present? && item.text.present? }
  end

  def search_for_type(
    type,
    guardian,
    term,
    limit,
    condition = HashtagAutocompleteService.search_conditions[:contains]
  )
    filter_valid_data_items(
      set_types(set_refs(@@data_sources[type].search(guardian, term, limit, condition)), type),
    )
  end

  def execute_lookup!(lookup_results, type, guardian, slugs)
    found_from_slugs = filter_valid_data_items(lookup_for_type(type, guardian, slugs))
    found_from_slugs.sort_by! { |item| item.text.downcase }

    if lookup_results.present?
      lookup_results[type.to_sym] = lookup_results[type.to_sym].concat(found_from_slugs)
    end

    found_from_slugs
  end

  def lookup_for_type(type, guardian, slugs)
    set_types(set_refs(@@data_sources[type].lookup(guardian, slugs)), type)
  end

  def append_types_to_conflicts(limited_results, top_ranked_type, limit)
    limited_results.each do |hashtag_item|
      next if hashtag_item.type == top_ranked_type

      other_slugs = limited_results.reject { |r| r.type === hashtag_item.type }.map(&:slug)
      if other_slugs.include?(hashtag_item.slug)
        hashtag_item.ref = "#{hashtag_item.slug}::#{hashtag_item.type}"
      end
    end

    limited_results.take(limit)
  end
end
