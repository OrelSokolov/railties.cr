# CRails::PropshaftHelper — порт Propshaft::Helper (propshaft 1.3.2,
# lib/propshaft/helper.rb): compute_asset_path через resolver сборки
# (Static при существующем манифесте — precompiled, Dynamic — dev).
#
# Подключается в ApplicationController приложения (`crails new` делает
# это по умолчанию; аналог ActiveSupport.on_load(:action_view) гема).
# Отсутствующий ассет → Propshaft::MissingAssetError — паритет с гемом.
#
# SRI (asset_integrity) — sha256/sha384/sha512 от compiled_content.

module CRails
  module PropshaftHelper
    # Оверрайд ActionView::Helpers::AssetTagHelper#compute_asset_path.
    # Блок (dir-конвенция "stylesheets/<s>.css" без пайплайна)
    # игнорируется — как в Rails с propshaft резолв идёт по load path.
    def compute_asset_path(source : String) : String
      CRails.application.assets.resolver.resolve(source) ||
        raise(Propshaft::MissingAssetError.new(source))
    end

    # Subresource Integrity для тега (integrity: true в хелперах — P2
    # из importmap_cr/PLAN.md, теперь реализуемо):
    #   stylesheet_link_tag "application" — integrity отдельным вызовом.
    def asset_integrity(path : String, hash_algorithm : String = "sha384") : String
      CRails.application.assets.load_path.find(path)
        .try(&.integrity(hash_algorithm)) ||
        raise(Propshaft::MissingAssetError.new(path))
    end
  end
end
