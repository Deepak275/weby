module Journal::Admin
  class NewsController < Journal::ApplicationController
    # include ActsToToggle

    before_action :require_user
    before_action :check_authorization
    before_action :status_types, only: [:new, :edit, :create, :update, :index]

    respond_to :html, :js

    helper_method :sort_column

    def index
      @newslist = get_news
      @newsletter = current_site.active_skin.components.find_by_name("newsletter")
      respond_with(:admin, @newslist) do |format|
        if params[:template]
          format.js { render "#{params[:template]}" }
          format.html { render partial: "#{params[:template]}", layout: false }
        end
      end
    end

    def recycle_bin
      params[:sort] ||= 'journal_news.deleted_at'
      params[:direction] ||= 'desc'
      @newslist = Journal::News.all.trashed.where(site_id: current_site.id).includes(:user).
        order("#{params[:sort]} #{sort_direction}").
        page(params[:page]).per(params[:per_page])
    end

    def get_news
      case params[:template]
      when 'tiny_mce'
        params[:per_page] = 7
      end
      params[:direction] ||= 'desc'

      news_sites = current_site.news_sites
      @news = []
      news_sites.each do |sites|
        @news << sites.journal_news_id
      end

      news = Journal::News.where('journal_news.id in (?)', @news).
        includes(:user).
        search(params[:search], 1) # 1 = busca com AND entre termos

      if params[:template] == 'list_popup'
        news = news.published
      end
      if sort_column == 'journal_news_i18ns.title'
         news = news.includes(i18ns: :locale).where(locales: {name: I18n.locale})
      end
      if sort_column == 'tags.name'
         news = news.includes(news_sites: {categories: :taggings})
      end
      if sort_column == 'journal_news.front'
         news = news.includes(:news_sites)
      end
      if params[:status_filter].present? && Journal::News::STATUS_LIST.include?(params[:status_filter])
        news = news.send(params[:status_filter])
      end

      news = news.order(sort_column + ' ' + sort_direction).page(params[:page]).per(params[:per_page])
    end

    private :get_news

    # Essa action não chama o get_news pois não faz paginação
    def fronts
      @newslist = current_site.news_sites.available_fronts.order('position desc')
    end

    def show
      @news = current_site.news.find(params[:id]).in(params[:show_locale])
      respond_with(:admin, @news)
    end

    def new
      @news = Journal::News.new(site_id: current_site)
      @news.news_sites.build(site_id: current_site)
      @draft = get_draft('')
    end

    def edit
      @news = current_site.news.find(params[:id])
      @draft = get_draft(@news.id)
    end

    def share
      @news_site = Journal::NewsSite.where(news: params[:id], site: params[:site_id])
      if @news_site.size < 1
        @news = Journal::News.find(params[:id])

        @news.news_sites.new(site_id: params[:site_id], journal_news_id: params[:id], front: true)
        @news.save
        @news_site = Journal::NewsSite.where(news: params[:id], site: params[:site_id]).first
        @news_site.category_list.add("#{params[:tag]}")
        @news_site.save
      end
       redirect_to :back
    end

    def unshare
      @news = Journal::NewsSite.where(site_id: current_site.id, journal_news_id: params[:id])
      @news.destroy_all
      redirect_to :back
    end

    def create
      @news = Journal::News.new(news_params)
      @news.site = current_site
      @news.user = current_user
      if @news.save
        set_draft(nil, '')
      end
      record_activity('created_news', @news)
      respond_with(:admin, @news)
    end

    def update
      params[:news][:related_file_ids] ||= []
      @news = current_site.news.find(params[:id])
      if @news.update(news_params)
        set_draft(nil, @news.id)
      end
      record_activity('updated_news', @news)
      respond_with(:admin, @news)
    end

    def update_draft
      if set_draft(params[:news], params[:news_id])
        render json: {ok: true, message: t('.draft_saved')}
      else
        render json: {ok: false}
      end
    end

    def restore_draft
      render json: get_draft(params[:news_id])
    end

    def cancel
      set_draft(nil, params[:news_id])
      redirect_to admin_news_index_path
    end

    def toggle
      news_sites = Journal::NewsSite.find(params[:id])
      news_sites.toggle! :front
      redirect_to :back
    end

    def status_types
      @status_types = Journal::News::STATUS_LIST.map { |el| [t("journal.admin.news.form.#{el}"), el] }
    end
    private :status_types

    def destroy
      @news = current_site.news.unscoped.find(params[:id])
      if @news.trash
        if @news.persisted?
          record_activity('moved_news_to_recycle_bin', @news)
          flash[:success] = t('moved_news_to_recycle_bin')
        else
          record_activity('destroyed_news', @news)
          flash[:success] = t('successfully_deleted')
        end
      else
        flash[:error] = @news.errors.full_messages.join(', ')
      end

      redirect_to @news.persisted? ? admin_news_index_path : recycle_bin_admin_news_index_path
    end

    def recover
      @news = current_site.news.trashed.find(params[:id])
      if @news.untrash
        flash[:success] = t('successfully_restored')
      end
      record_activity('restored_news', @news)
      redirect_to :back
    end

    def newsletter
      @news = Journal::News.unscoped.where(site_id: current_site).find(params[:id]).in(params[:show_locale])
      @newsletter = Weby::Components.factory(current_site.active_skin.components.find_by_name('newsletter'))
      @emails_id = Journal::Newsletter.by_site(current_site.id).ids.join(",")
      @emails_value = Journal::Newsletter.show_emails(current_site.id)
      @histories = Journal::NewsletterHistories.sent(current_site.id, @news.id)
      @order_by_emails = Journal::Newsletter.by_site(current_site.id).order('email')
      respond_with(:admin, @news)
    end

    def newsletter_histories
      if (params[:from].blank? || params[:to].blank? || params[:subject].blank?)
        flash[:error] = t('.field_blank')
        redirect_to :back
      else
        history = Journal::NewsletterHistories.new
        history.site_id = current_site.id
        history.news_id = params[:id]
	      history.user_id = current_user.id
        history.emails = params[:ids]
        history.save
        news = Journal::News.where(site_id: current_site).find(params[:id]).in(params[:show_locale])
        Journal::NewsletterMailer.news_email(params[:from], params[:to], params[:subject], current_site, news).deliver
        flash[:success] = t('.successfully_send')
        redirect_to admin_news_index_path
      end
    end

    private

    def set_draft value, news_id
      current_user.preferences['draft'] ||= {}
      current_user.preferences['draft'][current_site.id] ||= {}
      current_user.preferences['draft'][current_site.id][news_id] = value
      current_user.save
    end

    def get_draft news_id
      current_user.preferences.dig('draft', current_site.id.to_s, news_id.to_s)
    end

    def sort_column
      params[:sort] || 'journal_news.id'
    end

    def news_params
      params.require(:news).permit(:source, :url,
                                   { news_sites_attributes: [:id, :site_id, :journal_news_id, :category_list,
                                                            :front, :date_begin_at,
                                                            :date_end_at] },
                                   :image, :status,
                                   { i18ns_attributes: [:id, :locale_id, :title,
                                       :summary, :text, :_destroy],
                                     related_file_ids: [] })
    end

  end
end
