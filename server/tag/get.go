package tag

import (
	"context"

	"github.com/jinzhu/copier"
	"momenttally.com/server/auth"
	"momenttally.com/server/generated/gqlmodel"
	"momenttally.com/server/model"
)

// LabelDefinitions returns all label definitions of the current user,
// including their per-value color overrides.
func (r *ResolverForTag) LabelDefinitions(ctx context.Context) ([]*gqlmodel.LabelDefinition, error) {
	var tags []model.TagDefinition
	userID := auth.GetUser(ctx).ID

	timeSpansIdsOfUser := r.DB.Model(new(model.TimeSpan)).
		Select("id").
		Where(&model.TimeSpan{UserID: userID}).
		SubQuery()
	usages := r.DB.Select("COUNT (*)").Where("time_span_tags.time_span_id in ?", timeSpansIdsOfUser).
		Where("tag_definitions.key = time_span_tags.key").
		Model(new(model.TimeSpanTag)).
		Group("time_span_tags.key").
		SubQuery()
	find := r.DB.Select("tag_definitions.*, ? as usages", usages).Where("user_id = ?", userID).Order("usages desc").Find(&tags)
	result := []*gqlmodel.LabelDefinition{}
	copier.Copy(&result, &tags)

	colors, err := valueColorsByKey(r.DB, userID)
	if err != nil {
		return nil, err
	}
	for i, definition := range result {
		// copier maps by field name; UpdatedAtUTC → UpdatedAt is manual.
		definition.UpdatedAt = model.Time(tags[i].UpdatedAtUTC)
		definition.ValueColors = []*gqlmodel.LabelValueColor{}
		if c, ok := colors[definition.Key]; ok {
			definition.ValueColors = c
		}
	}
	return result, find.Error
}
