{% extends '_layout.swig' %}
{% import '_macro/sidebar.swig' as sidebar_template %}

{% block title %}
  {% set page_title_suffix = ' | ' + config.title %}

  {% if page.type === "categories" %}
    {{ __('title.category') + page_title_suffix }}
  {% elif page.type === "tags" %}
    {{ __('title.tag') + page_title_suffix }}
  {% else %}
    {{ page.title + page_title_suffix }}
  {% endif %}
{% endblock %}

{% block content %}

  <div id="posts" class="posts-expand">
    {# tagcloud page support #}
    {% if page.type === "tags" %}
      <div class="tag-cloud">
        <div class="tag-cloud-title">
            {{ _p('counter.tag_cloud', site.tags.length) }}
        </div>
        <div class="tag-cloud-tags">
          {{ tagcloud({min_font: 12, max_font: 30, amount: 200, color: true, start_color: '#ccc', end_color: '#111'}) }}
        </div>
      </div>
    {% elif page.type === 'categories' %}
      <div class="category-all-page">
        <div class="category-all-title">
            {{ _p('counter.categories', site.categories.length) }}
        </div>
        <div class="category-all">
          {{ list_categories() }}
        </div>
      </div>
    {% else %}
      {{ page.content }}
    {% endif %}
  </div>
<div id="cloud-tie-wrapper" class="cloud-tie-wrapper"></div>
<script src="https://img1.cache.netease.com/f2e/tie/yun/sdk/loader.js"></script>
<script>
var cloudTieConfig = {
  url: document.location.href, 
  sourceId: "",
  productKey: "5f86fe3bc07e4e31adb4a20c48cbf8f2",
  target: "cloud-tie-wrapper"
};
var yunManualLoad = true;
Tie.loader("aHR0cHM6Ly9hcGkuZ2VudGllLjE2My5jb20vcGMvbGl2ZXNjcmlwdC5odG1s", true);
</script>
{% endblock %}

{% block sidebar %}
  {{ sidebar_template.render(false) }}
{% endblock %}

