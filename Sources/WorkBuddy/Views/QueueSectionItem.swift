/// LazyVStack combines rows from different ForEach blocks into one child list. Resource IDs alone cannot distinguish appearances in different categories; moving an item can reuse a row without updating content or menus. Presentation identity includes the section without changing the resource ID.
struct QueueSectionItem<Item: Identifiable>: Identifiable {
    struct ID: Hashable {
        let section: String
        let item: Item.ID
    }

    let section: String
    let item: Item

    var id: ID { ID(section: section, item: item.id) }
}
